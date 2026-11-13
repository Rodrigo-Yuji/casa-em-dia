alter table public.casa_pair_controls alter column member_b drop not null;
alter table public.casa_tasks add column deleted_at timestamptz;
alter table public.casa_pair_tasks add column deleted_at timestamptz;
create or replace function public.casa_pair_create(p_name text,p_other uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();m uuid;g uuid;
begin
 select id into m from public.casa_members where user_id=auth.uid();
 if h is null then raise exception 'Entre em uma casa.';end if;
 if p_other is not null and (m=p_other or not exists(select 1 from public.casa_members where id=p_other and household_id=h))then raise exception 'Escolha outro morador da sua casa.';end if;
 insert into public.casa_pair_controls(household_id,name,member_a,member_b,created_by)values(h,trim(p_name),m,p_other,auth.uid())returning id into g;
 return jsonb_build_object('id',g);
end $$;
create function public.casa_pair_rename(p_control uuid,p_name text)returns jsonb language plpgsql security definer set search_path=''as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);
begin
 if g.created_by<>auth.uid()then raise exception 'Só quem criou o controle pode gerenciá-lo.';end if;
 update public.casa_pair_controls set name=trim(p_name)where id=g.id;
 return jsonb_build_object('id',g.id,'name',trim(p_name));
end $$;
create function public.casa_pair_delete(p_control uuid)returns void language plpgsql security definer set search_path=''as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 if g.created_by<>auth.uid()then raise exception 'Só quem criou o controle pode excluí-lo.';end if;
 delete from casa_private.push_deliveries where task_id in(select id from public.casa_pair_tasks where control_id=g.id);
 delete from public.casa_pair_completions where control_id=g.id;
 delete from public.casa_pair_absences where control_id=g.id;
 delete from public.casa_pair_tasks where control_id=g.id;
 delete from public.casa_pair_controls where id=g.id;
end $$;
create function public.casa_delete_task(p_task_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare h uuid:=public.casa_my_household();
begin
 if h is null then raise exception 'Entre em uma casa.';end if;
 perform 1 from public.casa_households where id=h for update;
 update public.casa_tasks set active=false,deleted_at=now()where id=p_task_id and household_id=h and deleted_at is null;
 if not found then raise exception 'Tarefa indisponível.';end if;
 return public.casa_snapshot();
end $$;
create function public.casa_pair_delete_task(p_control uuid,p_task_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 update public.casa_pair_tasks set active=false,deleted_at=now()where id=p_task_id and control_id=g.id and deleted_at is null;
 if not found then raise exception 'Tarefa indisponível.';end if;
 return public.casa_pair_snapshot(g.id);
end $$;

create or replace function public.casa_snapshot() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if h is null then return null; end if;
 return jsonb_build_object(
 'household',(select to_jsonb(x) from public.casa_households x where id=h),
 'members',coalesce((select jsonb_agg(x order by created_at) from public.casa_members x where household_id=h),'[]'::jsonb),
 'tasks',coalesce((select jsonb_agg(x order by due_time) from public.casa_tasks x where household_id=h and deleted_at is null),'[]'::jsonb),
 'absences',coalesce((select jsonb_agg(x order by starts_on) from public.casa_absences x where household_id=h),'[]'::jsonb),
 'completions',coalesce((select jsonb_agg(x order by completed_at desc) from public.casa_completions x where household_id=h),'[]'::jsonb),
 'settlements',coalesce((select jsonb_agg(x order by created_at desc) from public.casa_settlements x where household_id=h),'[]'::jsonb));
end $$;


create or replace function public.casa_pair_snapshot(p_control uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);h public.casa_households;
begin
 select * into h from public.casa_households where id=g.household_id;
 return jsonb_build_object('scope','pair','control_id',g.id,
 'household',jsonb_build_object('id',h.id,'name',g.name,'timezone',h.timezone,'owner_id',g.created_by),
 'members',(select jsonb_agg(m order by m.created_at,m.id) from public.casa_members m where m.id in(g.member_a,g.member_b)),
 'tasks',coalesce((select jsonb_agg(t order by t.due_time,t.id) from public.casa_pair_tasks t where t.control_id=g.id and t.deleted_at is null),'[]'::jsonb),
 'absences',coalesce((select jsonb_agg(a order by a.starts_on) from public.casa_pair_absences a where a.control_id=g.id),'[]'::jsonb),
 'completions',coalesce((select jsonb_agg(c order by c.completed_at desc) from public.casa_pair_completions c where c.control_id=g.id),'[]'::jsonb),'settlements','[]'::jsonb);
end $$;

create or replace function casa_private.assignments(p_household uuid,p_date date)
returns table(task_id uuid,effective_member_id uuid,redistributed boolean)
language plpgsql stable security definer set search_path='' as $$
declare
 today_date date; start_date date; work_date date; rec record; member_rec record; done public.casa_completions;
 last_done jsonb:='{}'::jsonb; deferred jsonb:='{}'::jsonb; day_load jsonb; day_count jsonb; initial_preference jsonb; preferred uuid;
 chosen uuid; chosen_rank numeric; candidate_rank numeric; best_load integer; candidate_load integer; best_count integer; candidate_count integer;
 tick numeric:=extract(epoch from now()); member_key text; task_key text; picked_rank numeric; candidate_hold numeric; best_hold numeric;
begin
 select (now() at time zone h.timezone)::date into today_date from public.casa_households h where h.id=p_household;
 if today_date is null then return; end if;
 if p_date>today_date+366 then raise exception 'Consulte até um ano de previsão.'; end if;
 start_date:=least(p_date,today_date);
 for rec in select c.* from public.casa_completions c where c.household_id=p_household and c.occurrence_date<start_date order by c.completed_at,c.id loop
 member_key:=rec.task_id::text||':'||rec.completed_by::text;
 last_done:=jsonb_set(last_done,array[member_key],to_jsonb(extract(epoch from rec.completed_at)));
 deferred:=deferred-member_key;
 if rec.original_member_id<>rec.completed_by then
 member_key:=rec.task_id::text||':'||rec.original_member_id::text;
 if not deferred ? member_key then deferred:=jsonb_set(deferred,array[member_key],to_jsonb(extract(epoch from rec.completed_at)));end if;
 end if;
 end loop;
 work_date:=start_date;
 while work_date<=p_date loop
 day_load:='{}'::jsonb;day_count:='{}'::jsonb;
 -- Stable initial balancing depends only on task metadata and availability.
 initial_preference:='{}'::jsonb;
 for rec in select t.* from public.casa_tasks t
 where t.household_id=p_household and t.deleted_at is null and
 ((t.active and casa_private.is_due(t.recurrence,t.starts_on,t.interval_days,work_date))
 or exists(select 1 from public.casa_completions c where c.task_id=t.id and c.occurrence_date=work_date))
 order by t.duration_minutes desc,t.id loop
 chosen:=null;best_load:=null;best_count:=null;
 for member_rec in select m.* from public.casa_members m where m.household_id=p_household
 and not exists(select 1 from public.casa_absences a where a.member_id=m.id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date))
 order by (m.id=rec.assignee_id) desc,m.id loop
 candidate_load:=coalesce((day_load->>member_rec.id::text)::integer,0);
 candidate_count:=coalesce((day_count->>member_rec.id::text)::integer,0);
 if chosen is null or candidate_load<best_load or (candidate_load=best_load and candidate_count<best_count) then
 chosen:=member_rec.id;best_load:=candidate_load;best_count:=candidate_count;
 end if;
 end loop;
 if chosen is not null then
 initial_preference:=jsonb_set(initial_preference,array[rec.id::text],to_jsonb(chosen));
 day_load:=jsonb_set(day_load,array[chosen::text],to_jsonb(coalesce((day_load->>chosen::text)::integer,0)+rec.duration_minutes));
 day_count:=jsonb_set(day_count,array[chosen::text],to_jsonb(coalesce((day_count->>chosen::text)::integer,0)+1));
 end if;
 end loop;
 for rec in select t.* from public.casa_tasks t
 where t.household_id=p_household and t.deleted_at is null and
 ((t.active and casa_private.is_due(t.recurrence,t.starts_on,t.interval_days,work_date))
 or exists(select 1 from public.casa_completions c where c.task_id=t.id and c.occurrence_date=work_date))
 order by t.duration_minutes desc,t.id loop
 select c.* into done from public.casa_completions c where c.task_id=rec.id and c.occurrence_date=work_date;
 task_key:=rec.id::text;chosen:=null;
 if done.id is not null then
 chosen:=done.original_member_id;
 tick:=tick+1;member_key:=task_key||':'||done.completed_by::text;
 last_done:=jsonb_set(last_done,array[member_key],to_jsonb(tick));deferred:=deferred-member_key;
 if done.original_member_id<>done.completed_by then
 member_key:=task_key||':'||done.original_member_id::text;
 if not deferred ? member_key then deferred:=jsonb_set(deferred,array[member_key],to_jsonb(tick));end if;
 end if;
 else
 chosen_rank:=null;best_hold:=null;preferred:=(initial_preference->>rec.id::text)::uuid;
 for member_rec in select m.* from public.casa_members m where m.household_id=p_household
 and not exists(select 1 from public.casa_absences a where a.member_id=m.id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date))
 order by (m.id<preferred),m.id loop
 member_key:=member_rec.id::text;
 candidate_rank:=case when deferred ? (task_key||':'||member_key) then -2 else coalesce((last_done->>(task_key||':'||member_key))::numeric,-1) end;
 candidate_hold:=coalesce((deferred->>(task_key||':'||member_key))::numeric,0);
 if chosen is null or candidate_rank<chosen_rank or
 (candidate_rank=chosen_rank and candidate_hold<best_hold) then
 chosen:=member_rec.id;chosen_rank:=candidate_rank;best_hold:=candidate_hold;
 end if;
 end loop;
 if chosen is not null then
 member_key:=chosen::text;tick:=tick+1;
 last_done:=jsonb_set(last_done,array[task_key||':'||member_key],to_jsonb(tick));
 deferred:=deferred-(task_key||':'||member_key);
 end if;
 end if;
 if work_date=p_date then
 task_id:=rec.id;effective_member_id:=chosen;
 redistributed:=exists(select 1 from public.casa_absences a where a.member_id=rec.assignee_id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date));
 return next;
 end if;
 end loop;
 work_date:=work_date+1;
 end loop;
end $$;



revoke all on function casa_private.assignments(uuid,date) from public,anon,authenticated;


create or replace function casa_private.pair_assignments(p_control uuid,p_date date)
returns table(task_id uuid,effective_member_id uuid,redistributed boolean)
language plpgsql stable security definer set search_path='' as $$
declare
 today_date date; start_date date; work_date date; rec record; member_rec record; done public.casa_pair_completions;
 last_done jsonb:='{}'::jsonb; deferred jsonb:='{}'::jsonb; day_load jsonb; day_count jsonb; initial_preference jsonb; preferred uuid;
 chosen uuid; chosen_rank numeric; candidate_rank numeric; best_load integer; candidate_load integer; best_count integer; candidate_count integer;
 tick numeric:=extract(epoch from now()); member_key text; task_key text; picked_rank numeric; candidate_hold numeric; best_hold numeric;
begin
 select (now() at time zone h.timezone)::date into today_date from public.casa_households h join public.casa_pair_controls g on g.household_id=h.id where g.id=p_control;
 if today_date is null then return; end if;
 if p_date>today_date+366 then raise exception 'Consulte até um ano de previsão.'; end if;
 start_date:=least(p_date,today_date);
 for rec in select c.* from public.casa_pair_completions c where c.control_id=p_control and c.occurrence_date<start_date order by c.completed_at,c.id loop
 member_key:=rec.task_id::text||':'||rec.completed_by::text;
 last_done:=jsonb_set(last_done,array[member_key],to_jsonb(extract(epoch from rec.completed_at)));
 deferred:=deferred-member_key;
 if rec.original_member_id<>rec.completed_by then
 member_key:=rec.task_id::text||':'||rec.original_member_id::text;
 if not deferred ? member_key then deferred:=jsonb_set(deferred,array[member_key],to_jsonb(extract(epoch from rec.completed_at)));end if;
 end if;
 end loop;
 work_date:=start_date;
 while work_date<=p_date loop
 day_load:='{}'::jsonb;day_count:='{}'::jsonb;
 -- Stable initial balancing depends only on task metadata and availability.
 initial_preference:='{}'::jsonb;
 for rec in select t.* from public.casa_pair_tasks t
 where t.control_id=p_control and t.deleted_at is null and
 ((t.active and casa_private.is_due(t.recurrence,t.starts_on,t.interval_days,work_date))
 or exists(select 1 from public.casa_pair_completions c where c.task_id=t.id and c.occurrence_date=work_date))
 order by t.duration_minutes desc,t.id loop
 chosen:=null;best_load:=null;best_count:=null;
 for member_rec in select m.* from public.casa_members m where m.id in(select g.member_a from public.casa_pair_controls g where g.id=p_control union all select g.member_b from public.casa_pair_controls g where g.id=p_control)
 and not exists(select 1 from public.casa_pair_absences a where a.control_id=p_control and a.member_id=m.id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date))
 order by (m.id=rec.assignee_id) desc,m.id loop
 candidate_load:=coalesce((day_load->>member_rec.id::text)::integer,0);
 candidate_count:=coalesce((day_count->>member_rec.id::text)::integer,0);
 if chosen is null or candidate_load<best_load or (candidate_load=best_load and candidate_count<best_count) then
 chosen:=member_rec.id;best_load:=candidate_load;best_count:=candidate_count;
 end if;
 end loop;
 if chosen is not null then
 initial_preference:=jsonb_set(initial_preference,array[rec.id::text],to_jsonb(chosen));
 day_load:=jsonb_set(day_load,array[chosen::text],to_jsonb(coalesce((day_load->>chosen::text)::integer,0)+rec.duration_minutes));
 day_count:=jsonb_set(day_count,array[chosen::text],to_jsonb(coalesce((day_count->>chosen::text)::integer,0)+1));
 end if;
 end loop;
 for rec in select t.* from public.casa_pair_tasks t
 where t.control_id=p_control and t.deleted_at is null and
 ((t.active and casa_private.is_due(t.recurrence,t.starts_on,t.interval_days,work_date))
 or exists(select 1 from public.casa_pair_completions c where c.task_id=t.id and c.occurrence_date=work_date))
 order by t.duration_minutes desc,t.id loop
 select c.* into done from public.casa_pair_completions c where c.task_id=rec.id and c.occurrence_date=work_date;
 task_key:=rec.id::text;chosen:=null;
 if done.id is not null then
 chosen:=done.original_member_id;
 tick:=tick+1;member_key:=task_key||':'||done.completed_by::text;
 last_done:=jsonb_set(last_done,array[member_key],to_jsonb(tick));deferred:=deferred-member_key;
 if done.original_member_id<>done.completed_by then
 member_key:=task_key||':'||done.original_member_id::text;
 if not deferred ? member_key then deferred:=jsonb_set(deferred,array[member_key],to_jsonb(tick));end if;
 end if;
 else
 chosen_rank:=null;best_hold:=null;preferred:=(initial_preference->>rec.id::text)::uuid;
 for member_rec in select m.* from public.casa_members m where m.id in(select g.member_a from public.casa_pair_controls g where g.id=p_control union all select g.member_b from public.casa_pair_controls g where g.id=p_control)
 and not exists(select 1 from public.casa_pair_absences a where a.control_id=p_control and a.member_id=m.id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date))
 order by (m.id<preferred),m.id loop
 member_key:=member_rec.id::text;
 candidate_rank:=case when deferred ? (task_key||':'||member_key) then -2 else coalesce((last_done->>(task_key||':'||member_key))::numeric,-1) end;
 candidate_hold:=coalesce((deferred->>(task_key||':'||member_key))::numeric,0);
 if chosen is null or candidate_rank<chosen_rank or
 (candidate_rank=chosen_rank and candidate_hold<best_hold) then
 chosen:=member_rec.id;chosen_rank:=candidate_rank;best_hold:=candidate_hold;
 end if;
 end loop;
 if chosen is not null then
 member_key:=chosen::text;tick:=tick+1;
 last_done:=jsonb_set(last_done,array[task_key||':'||member_key],to_jsonb(tick));
 deferred:=deferred-(task_key||':'||member_key);
 end if;
 end if;
 if work_date=p_date then
 task_id:=rec.id;effective_member_id:=chosen;
 redistributed:=exists(select 1 from public.casa_pair_absences a where a.control_id=p_control and a.member_id=rec.assignee_id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date));
 return next;
 end if;
 end loop;
 work_date:=work_date+1;
 end loop;
end $$;



revoke all on function casa_private.pair_assignments(uuid,date) from public,anon,authenticated;




create or replace function public.casa_save_task(p_task jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household(); tid uuid:=(p_task->>'id')::uuid;
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 if tid is null then
  insert into public.casa_tasks(household_id,title,emoji,assignee_id,starts_on,due_time,recurrence,duration_minutes,interval_days)
  values(h,trim(p_task->>'title'),p_task->>'emoji',(p_task->>'assignee_id')::uuid,(p_task->>'starts_on')::date,
  (p_task->>'due_time')::time,p_task->>'recurrence',(p_task->>'duration_minutes')::integer,coalesce((p_task->>'interval_days')::integer,1));
 else
  update public.casa_tasks set title=trim(p_task->>'title'),emoji=p_task->>'emoji',assignee_id=(p_task->>'assignee_id')::uuid,
  starts_on=(p_task->>'starts_on')::date,due_time=(p_task->>'due_time')::time,recurrence=p_task->>'recurrence',
  duration_minutes=(p_task->>'duration_minutes')::integer,interval_days=coalesce((p_task->>'interval_days')::integer,1),active=coalesce((p_task->>'active')::boolean,true)
  where id=tid and household_id=h and deleted_at is null;
  if not found then raise exception 'Tarefa não encontrada.'; end if;
 end if;
 return public.casa_snapshot();
end $$;


create or replace function public.casa_pair_save_task(p_control uuid,p_task jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);tid uuid:=(p_task->>'id')::uuid;assignee uuid:=(p_task->>'assignee_id')::uuid;
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 if assignee is null or (assignee is distinct from g.member_a and assignee is distinct from g.member_b) then raise exception 'Participante inválido.';end if;
 if tid is null then
 insert into public.casa_pair_tasks(control_id,title,emoji,assignee_id,starts_on,due_time,recurrence,interval_days,duration_minutes)
 values(g.id,trim(p_task->>'title'),p_task->>'emoji',assignee,(p_task->>'starts_on')::date,(p_task->>'due_time')::time,p_task->>'recurrence',coalesce((p_task->>'interval_days')::integer,1),(p_task->>'duration_minutes')::integer);
 else
 update public.casa_pair_tasks set title=trim(p_task->>'title'),emoji=p_task->>'emoji',assignee_id=assignee,starts_on=(p_task->>'starts_on')::date,due_time=(p_task->>'due_time')::time,recurrence=p_task->>'recurrence',interval_days=coalesce((p_task->>'interval_days')::integer,1),duration_minutes=(p_task->>'duration_minutes')::integer,active=coalesce((p_task->>'active')::boolean,true) where id=tid and control_id=g.id and deleted_at is null;
 if not found then raise exception 'Tarefa indisponível.';end if;
 end if;return public.casa_pair_snapshot(g.id);
end $$;

create or replace function public.casa_pair_save_absence(p_control uuid,p_member_id uuid,p_start date,p_end date default null,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 if p_member_id is null or (p_member_id is distinct from g.member_a and p_member_id is distinct from g.member_b) then raise exception 'Participante inválido.';end if;
 insert into public.casa_pair_absences(control_id,member_id,starts_on,ends_on,reason)values(g.id,p_member_id,p_start,p_end,p_reason);
 return public.casa_pair_snapshot(g.id);
end $$;

do $$declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and p.proname in('casa_pair_rename','casa_pair_delete','casa_delete_task','casa_pair_delete_task')loop
 execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
revoke all on all functions in schema casa_private from public,anon,authenticated;
