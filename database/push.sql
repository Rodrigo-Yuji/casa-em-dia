create table casa_private.push_config (
 singleton boolean primary key default true check(singleton),
 vapid_public text not null, vapid_private text not null, cron_token text not null,
 site_url text not null default 'https://casa-em-dia-compartilhada.adoredfruit4.chatgpt.site'
);
create table public.casa_push_subscriptions (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.casa_members(id),
 endpoint text not null unique check(length(endpoint)<4096), p256dh text not null, auth text not null,
 created_at timestamptz not null default now()
);
create index casa_push_member_idx on public.casa_push_subscriptions(member_id);
alter table public.casa_push_subscriptions enable row level security;
revoke all on public.casa_push_subscriptions from anon,authenticated;
create policy own_push on public.casa_push_subscriptions for select to authenticated using(member_id in (select id from public.casa_members where user_id=(select auth.uid())));
grant select on public.casa_push_subscriptions to authenticated;
create table casa_private.push_deliveries (
 subscription_id uuid not null references public.casa_push_subscriptions(id) on delete cascade,
 task_id uuid not null references public.casa_tasks(id), occurrence_date date not null,
 claimed_at timestamptz not null default now(), sent_at timestamptz,
 attempts integer not null default 1,
 primary key(subscription_id,task_id,occurrence_date)
);
create function public.casa_push_public_key() returns text language sql stable security definer set search_path='' as $$
 select vapid_public from casa_private.push_config where singleton
$$;
create function public.casa_subscribe_push(p_subscription jsonb) returns void language plpgsql security definer set search_path='' as $$
declare m uuid; endpoint_value text:=p_subscription->>'endpoint'; hostname text;
begin
 select id into m from public.casa_members where user_id=auth.uid();
 if m is null then raise exception 'Entre em uma casa.'; end if;
 hostname:=split_part(split_part(endpoint_value,'/',3),':',1);
 if endpoint_value not like 'https://%' or not (hostname='fcm.googleapis.com' or hostname='updates.push.services.mozilla.com' or hostname like '%.push.apple.com' or hostname='web.push.apple.com' or hostname like '%.notify.windows.com') then raise exception 'Provedor de notificações não suportado.'; end if;
 if length(p_subscription->'keys'->>'p256dh') not between 40 and 200 or length(p_subscription->'keys'->>'auth') not between 16 and 100 then raise exception 'Assinatura inválida.'; end if;
 insert into public.casa_push_subscriptions(member_id,endpoint,p256dh,auth) values(m,endpoint_value,p_subscription->'keys'->>'p256dh',p_subscription->'keys'->>'auth')
 on conflict(endpoint) do update set p256dh=excluded.p256dh,auth=excluded.auth where public.casa_push_subscriptions.member_id=m;
end $$;
create function public.casa_unsubscribe_push(p_endpoint text) returns void language sql security definer set search_path='' as $$
 delete from public.casa_push_subscriptions where endpoint=p_endpoint and member_id=(select id from public.casa_members where user_id=auth.uid())
$$;
create function public.casa_push_config_service() returns jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(c) from casa_private.push_config c where singleton
$$;
create function public.casa_push_test_subscriptions(p_user uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(s),'[]'::jsonb) from public.casa_push_subscriptions s join public.casa_members m on m.id=s.member_id where m.user_id=p_user
$$;
create function public.casa_push_due() returns jsonb language sql stable security definer set search_path='' as $$
 with dates as (select h.id,(now() at time zone h.timezone)::date as day,(now() at time zone h.timezone)::time as local_time from public.casa_households h),
 candidates as (
 select s.id as subscription_id,s.endpoint,s.p256dh,s.auth,t.id as task_id,t.title,t.emoji,d.day as occurrence_date
 from dates d cross join lateral casa_private.assignments(d.id,d.day) a
 join public.casa_tasks t on t.id=a.task_id and t.active
 join public.casa_push_subscriptions s on s.member_id=a.effective_member_id
 where t.due_time<=d.local_time and t.due_time>=d.local_time-interval '15 minutes'
 and not exists(select 1 from public.casa_completions c where c.task_id=t.id and c.occurrence_date=d.day)
 and not exists(select 1 from casa_private.push_deliveries l where l.subscription_id=s.id and l.task_id=t.id and l.occurrence_date=d.day and (l.sent_at is not null or l.attempts>=3 or l.claimed_at>now()-interval '2 minutes'))
 order by t.due_time limit 100)
 select coalesce(jsonb_agg(candidates),'[]'::jsonb) from candidates
$$;
create function public.casa_push_claim(p_subscription uuid,p_task uuid,p_date date) returns boolean language plpgsql security definer set search_path='' as $$
declare claimed uuid;
begin
 insert into casa_private.push_deliveries(subscription_id,task_id,occurrence_date) values(p_subscription,p_task,p_date)
 on conflict(subscription_id,task_id,occurrence_date) do update set claimed_at=now(),attempts=casa_private.push_deliveries.attempts+1
 where casa_private.push_deliveries.sent_at is null and casa_private.push_deliveries.attempts<3 and casa_private.push_deliveries.claimed_at<now()-interval '2 minutes'
 returning subscription_id into claimed;
 return claimed is not null;
end $$;
create function public.casa_push_finish(p_subscription uuid,p_task uuid,p_date date,p_expired boolean default false) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_expired then delete from public.casa_push_subscriptions where id=p_subscription;
 else update casa_private.push_deliveries set sent_at=now() where subscription_id=p_subscription and task_id=p_task and occurrence_date=p_date; end if;
end $$;
do $$
declare f record;
begin
 for f in select p.oid::regprocedure as signature,p.proname as name from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'casa_push_%' or n.nspname='public' and p.proname in ('casa_subscribe_push','casa_unsubscribe_push')
 loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 if f.name in ('casa_push_public_key','casa_subscribe_push','casa_unsubscribe_push') then
 execute format('grant execute on function %s to authenticated',f.signature);
 else execute format('grant execute on function %s to service_role',f.signature); end if;
 end loop;
end $$;
