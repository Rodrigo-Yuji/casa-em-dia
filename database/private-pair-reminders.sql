-- The delivery log now accepts IDs from either isolated task table; access remains service-only.
alter table casa_private.push_deliveries drop constraint push_deliveries_task_id_fkey;
create or replace function public.casa_push_due() returns jsonb language sql stable security definer set search_path='' as $$
 with dates as(select h.id,(now() at time zone h.timezone)::date as day,(now() at time zone h.timezone)::time as local_time from public.casa_households h),
 candidates as(
 select s.id as subscription_id,s.endpoint,s.p256dh,s.auth,t.id as task_id,t.title,t.emoji,d.day as occurrence_date,null::uuid as control_id
 from dates d cross join lateral casa_private.assignments(d.id,d.day) a
 join public.casa_tasks t on t.id=a.task_id and t.active
 join public.casa_push_subscriptions s on s.member_id=a.effective_member_id
 where t.due_time<=d.local_time and t.due_time>=d.local_time-interval '15 minutes'
 and not exists(select 1 from public.casa_completions c where c.task_id=t.id and c.occurrence_date=d.day)
 union all
 select s.id,s.endpoint,s.p256dh,s.auth,t.id,t.title,t.emoji,d.day,g.id
 from dates d join public.casa_pair_controls g on g.household_id=d.id
 cross join lateral casa_private.pair_assignments(g.id,d.day)a
 join public.casa_pair_tasks t on t.id=a.task_id and t.active
 join public.casa_push_subscriptions s on s.member_id=a.effective_member_id
 where t.due_time<=d.local_time and t.due_time>=d.local_time-interval '15 minutes'
 and not exists(select 1 from public.casa_pair_completions c where c.task_id=t.id and c.occurrence_date=d.day)
 ),pending as(
 select c.* from candidates c where not exists(select 1 from casa_private.push_deliveries l where l.subscription_id=c.subscription_id and l.task_id=c.task_id and l.occurrence_date=c.occurrence_date and(l.sent_at is not null or l.attempts>=3 or l.claimed_at>now()-interval '2 minutes'))
 order by c.occurrence_date,c.task_id limit 100)
 select coalesce(jsonb_agg(pending),'[]'::jsonb)from pending
$$;
revoke all on function public.casa_push_due() from public,anon,authenticated;
grant execute on function public.casa_push_due() to service_role;
