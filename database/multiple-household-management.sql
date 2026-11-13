alter table public.casa_members drop constraint casa_members_user_id_key;
alter table public.casa_members add constraint casa_members_household_user_key unique(household_id,user_id);
alter table public.casa_members add column is_active boolean not null default true;
create index casa_members_user_active_idx on public.casa_members(user_id)where is_active;
create table public.casa_user_preferences(
 user_id uuid primary key references auth.users(id),current_household_id uuid references public.casa_households(id)on delete set null,
 default_household_id uuid references public.casa_households(id)on delete set null
);
create index casa_preferences_current_idx on public.casa_user_preferences(current_household_id);
create index casa_preferences_default_idx on public.casa_user_preferences(default_household_id);
alter table public.casa_user_preferences enable row level security;
create policy own_preferences_read on public.casa_user_preferences for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.casa_user_preferences from anon,authenticated;
grant select on public.casa_user_preferences to authenticated;
insert into public.casa_user_preferences(user_id,current_household_id,default_household_id)
 select user_id,household_id,household_id from public.casa_members where user_id is not null and is_active;
create or replace function public.casa_my_household()returns uuid language sql stable security definer set search_path=''as $$
 select m.household_id from public.casa_members m left join public.casa_user_preferences p on p.user_id=m.user_id
 where m.user_id=(select auth.uid())and m.is_active
 order by coalesce(m.household_id=p.current_household_id,false)desc,coalesce(m.household_id=p.default_household_id,false)desc,m.created_at,m.id limit 1
$$;
create function public.casa_household_list()returns jsonb language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',h.id,'name',h.name,'owner_id',h.owner_id,'member_id',m.id,'is_current',h.id=public.casa_my_household(),'is_default',coalesce(h.id=p.default_household_id,false))order by h.created_at,h.id),'[]'::jsonb)
 from public.casa_members m join public.casa_households h on h.id=m.household_id left join public.casa_user_preferences p on p.user_id=m.user_id
 where m.user_id=(select auth.uid())and m.is_active
$$;
create function public.casa_household_switch(p_household uuid)returns jsonb language plpgsql security definer set search_path=''as $$
begin
 if auth.uid()is null or not exists(select 1 from public.casa_members where user_id=auth.uid()and household_id=p_household and is_active)then raise exception 'Casa indisponível.';end if;
 insert into public.casa_user_preferences(user_id,current_household_id)values(auth.uid(),p_household)on conflict(user_id)do update set current_household_id=excluded.current_household_id;
 return public.casa_snapshot();
end $$;
create function public.casa_household_set_default(p_household uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 if auth.uid()is null or not exists(select 1 from public.casa_members where user_id=auth.uid()and household_id=p_household and is_active)then raise exception 'Casa indisponível.';end if;
 insert into public.casa_user_preferences(user_id,default_household_id)values(auth.uid(),p_household)on conflict(user_id)do update set default_household_id=excluded.default_household_id;
end $$;
create function public.casa_open_default_household()returns jsonb language plpgsql security definer set search_path=''as $$
declare target uuid;
begin
 select p.default_household_id into target from public.casa_user_preferences p join public.casa_members m on m.household_id=p.default_household_id and m.user_id=p.user_id and m.is_active where p.user_id=auth.uid();
 if target is not null then return public.casa_household_switch(target);end if;
 return public.casa_snapshot();
end $$;
create function public.casa_household_rename(p_household uuid,p_name text)returns void language plpgsql security definer set search_path=''as $$
begin
 update public.casa_households set name=trim(p_name)where id=p_household and owner_id=auth.uid();
 if not found then raise exception 'Só o responsável pela casa pode renomeá-la.';end if;
end $$;
create function public.casa_household_leave(p_household uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 perform 1 from public.casa_households where id=p_household for update;
 if exists(select 1 from public.casa_households where id=p_household and owner_id=auth.uid())then raise exception 'Você é o responsável por esta casa. Use Excluir casa para encerrar a casa que criou.';end if;
 update public.casa_members set is_active=false where household_id=p_household and user_id=auth.uid()and is_active;
 if not found then raise exception 'Casa indisponível.';end if;
 delete from public.casa_push_subscriptions where member_id in(select id from public.casa_members where household_id=p_household and user_id=auth.uid());
 update public.casa_user_preferences set current_household_id=case when current_household_id=p_household then null else current_household_id end,default_household_id=case when default_household_id=p_household then null else default_household_id end where user_id=auth.uid();
end $$;
create function public.casa_household_delete(p_household uuid,p_confirmation text)returns void language plpgsql security definer set search_path=''as $$
declare h public.casa_households;
begin
 select * into h from public.casa_households where id=p_household and owner_id=auth.uid()for update;
 if h.id is null then raise exception 'Só o responsável pela casa pode excluí-la.';end if;
 if p_confirmation is distinct from h.name then raise exception 'Digite o nome da casa exatamente como aparece para confirmar.';end if;
 delete from casa_private.push_deliveries where task_id in(select id from public.casa_tasks where household_id=h.id)or task_id in(select t.id from public.casa_pair_tasks t join public.casa_pair_controls g on g.id=t.control_id where g.household_id=h.id);
 delete from public.casa_push_subscriptions where member_id in(select id from public.casa_members where household_id=h.id);
 delete from public.casa_pair_completions where control_id in(select id from public.casa_pair_controls where household_id=h.id);
 delete from public.casa_pair_absences where control_id in(select id from public.casa_pair_controls where household_id=h.id);
 delete from public.casa_pair_tasks where control_id in(select id from public.casa_pair_controls where household_id=h.id);
 delete from public.casa_pair_controls where household_id=h.id;
 delete from public.casa_completions where household_id=h.id;
 delete from public.casa_settlements where household_id=h.id;
 delete from public.casa_absences where household_id=h.id;
 delete from public.casa_tasks where household_id=h.id;
 delete from public.casa_members where household_id=h.id;
 delete from public.casa_households where id=h.id;
end $$;
create or replace function public.casa_join_household(p_code uuid,p_person_name text,p_claim_id uuid default null)returns jsonb language plpgsql security definer set search_path=''as $$
declare h uuid;existing uuid;claimed uuid;
begin
 if auth.uid()is null then raise exception 'Entre na sua conta.';end if;
 select id into h from public.casa_households where invite_code=p_code for update;
 if h is null then raise exception 'Código de convite inválido.';end if;
 select id into existing from public.casa_members where household_id=h and user_id=auth.uid();
 if existing is not null then
 if p_claim_id is not null and p_claim_id<>existing then raise exception 'Sua conta já tem um perfil nesta casa.';end if;
 update public.casa_members set is_active=true where id=existing;
 elsif p_claim_id is not null then
 update public.casa_members set user_id=auth.uid()where id=p_claim_id and household_id=h and user_id is null and is_active returning id into claimed;
 if claimed is null then raise exception 'Esse perfil já está vinculado a outra conta.';end if;
 else insert into public.casa_members(household_id,user_id,name)values(h,auth.uid(),trim(p_person_name));end if;
 insert into public.casa_user_preferences(user_id,current_household_id,default_household_id)values(auth.uid(),h,h)on conflict(user_id)do update set current_household_id=excluded.current_household_id,default_household_id=coalesce(public.casa_user_preferences.default_household_id,excluded.default_household_id);
 return public.casa_snapshot();
end $$;
create or replace function public.casa_pair_can_access(p_control uuid)returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from public.casa_pair_controls g join public.casa_members m on m.id in(g.member_a,g.member_b)and m.household_id=g.household_id where g.id=p_control and m.user_id=(select auth.uid())and m.is_active)
$$;
create or replace function public.casa_pair_list()returns jsonb language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(g order by g.created_at),'[]'::jsonb)from public.casa_pair_controls g where g.household_id=public.casa_my_household()and public.casa_pair_can_access(g.id)
$$;

create or replace function public.casa_create_household(p_name text,p_person_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid; m uuid; d date:=(now() at time zone 'America/Sao_Paulo')::date;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 insert into public.casa_households(name,owner_id) values(trim(p_name),auth.uid()) returning id into h;
 insert into public.casa_members(household_id,user_id,name) values(h,auth.uid(),trim(p_person_name)) returning id into m;
 insert into public.casa_tasks(household_id,title,emoji,assignee_id,starts_on,due_time,duration_minutes) values
 (h,'Limpar a areia dos gatos','🐈',m,d,'08:00',5),(h,'Preparar a lava-louças','🍽️',m,d,'20:00',10);
 insert into public.casa_tasks(household_id,title,emoji,assignee_id,starts_on,due_time,recurrence,duration_minutes) values
 (h,'Lavar roupa','🧺',m,d,'10:00','weekly',30);
 insert into public.casa_user_preferences(user_id,current_household_id,default_household_id)values(auth.uid(),h,h)on conflict(user_id)do update set current_household_id=excluded.current_household_id,default_household_id=coalesce(public.casa_user_preferences.default_household_id,excluded.default_household_id);
 return public.casa_snapshot();
end $$;


do $$declare def text;signature text;begin
 foreach signature in array array['public.casa_undo_completion(uuid)','public.casa_pair_create(text,uuid)','public.casa_pair_complete_task(uuid,uuid,date,uuid)','public.casa_pair_undo_completion(uuid,uuid)','public.casa_invite_preview(uuid)','casa_private.assignments(uuid,date)','casa_private.pair_assignments(uuid,date)']loop
 select pg_get_functiondef(signature::regprocedure)into def;
 if signature='public.casa_undo_completion(uuid)'then def:=replace(def,'where user_id=auth.uid())','where user_id=auth.uid() and household_id=h and is_active)');
 elsif signature='public.casa_pair_create(text,uuid)'then def:=replace(def,'where user_id=auth.uid();','where user_id=auth.uid() and household_id=h and is_active;');
 elsif signature in('public.casa_pair_complete_task(uuid,uuid,date,uuid)','public.casa_pair_undo_completion(uuid,uuid)')then def:=replace(def,'where user_id=auth.uid();','where user_id=auth.uid() and household_id=g.household_id and is_active;');
 elsif signature='public.casa_invite_preview(uuid)'then def:=replace(def,'and user_id is null','and user_id is null and is_active');
 else def:=replace(def,'and not exists(select 1 from public.casa_absences','and m.is_active and not exists(select 1 from public.casa_absences');def:=replace(def,'and not exists(select 1 from public.casa_pair_absences','and m.is_active and not exists(select 1 from public.casa_pair_absences');end if;
 execute def;
 end loop;
end $$;
create or replace function public.casa_subscribe_push(p_subscription jsonb)returns void language plpgsql security definer set search_path=''as $$
declare m uuid;endpoint_value text:=p_subscription->>'endpoint';hostname text;
begin
 select id into m from public.casa_members where user_id=auth.uid()and household_id=public.casa_my_household()and is_active;
 if m is null then raise exception 'Entre em uma casa.';end if;
 hostname:=split_part(split_part(endpoint_value,'/',3),':',1);
 if endpoint_value not like 'https://%'or not(hostname='fcm.googleapis.com'or hostname='updates.push.services.mozilla.com'or hostname like '%.push.apple.com'or hostname like '%.notify.windows.com')then raise exception 'Provedor de notificações não suportado.';end if;
 if length(p_subscription->'keys'->>'p256dh')not between 40 and 200 or length(p_subscription->'keys'->>'auth')not between 16 and 100 then raise exception 'Assinatura inválida.';end if;
 insert into public.casa_push_subscriptions(member_id,endpoint,p256dh,auth)values(m,endpoint_value,p_subscription->'keys'->>'p256dh',p_subscription->'keys'->>'auth')
 on conflict(endpoint)do update set member_id=excluded.member_id,p256dh=excluded.p256dh,auth=excluded.auth where exists(select 1 from public.casa_members own where own.id=public.casa_push_subscriptions.member_id and own.user_id=auth.uid());
end $$;
create or replace function public.casa_unsubscribe_push(p_endpoint text)returns void language sql security definer set search_path=''as $$
 delete from public.casa_push_subscriptions where endpoint=p_endpoint and member_id in(select id from public.casa_members where user_id=auth.uid())
$$;
do $$declare def text;begin
 select pg_get_functiondef('public.casa_push_due()'::regprocedure)into def;
 def:=replace(def,'join public.casa_push_subscriptions s on s.member_id=a.effective_member_id','join public.casa_members recipient on recipient.id=a.effective_member_id and recipient.is_active join public.casa_members subscriber on subscriber.user_id=recipient.user_id and subscriber.is_active join public.casa_push_subscriptions s on s.member_id=subscriber.id');execute def;
end $$;
do $$declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and(p.proname like 'casa_household_%'or p.proname='casa_open_default_household')loop
 execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);end loop;
end $$;
revoke all on all functions in schema casa_private from public,anon,authenticated;
