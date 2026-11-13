-- Run after variable-recurrence.sql. Pair controls use separate tables and permissions.
create table public.casa_pair_controls (
 id uuid primary key default gen_random_uuid(),household_id uuid not null references public.casa_households(id),
 name text not null check(length(trim(name)) between 1 and 80),
 member_a uuid not null,member_b uuid not null,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),
 check(member_a<>member_b),foreign key(member_a,household_id)references public.casa_members(id,household_id),foreign key(member_b,household_id)references public.casa_members(id,household_id)
);
create index casa_pair_a_idx on public.casa_pair_controls(member_a,household_id);
create index casa_pair_b_idx on public.casa_pair_controls(member_b,household_id);
create index casa_pair_house_idx on public.casa_pair_controls(household_id);
create index casa_pair_creator_idx on public.casa_pair_controls(created_by);
create table public.casa_pair_tasks (
 id uuid primary key default gen_random_uuid(),control_id uuid not null references public.casa_pair_controls(id),
 title text not null check(length(trim(title)) between 1 and 120),emoji text not null default '🧹' check(length(emoji)<20),
 assignee_id uuid not null references public.casa_members(id),starts_on date not null,due_time time not null default '18:00',
 recurrence text not null default 'daily' check(recurrence in ('daily','weekly','once','interval')),interval_days integer not null default 1 check(interval_days between 1 and 365),
 duration_minutes integer not null default 10 check(duration_minutes between 1 and 360),active boolean not null default true,created_at timestamptz not null default now(),unique(id,control_id)
);
create index casa_pair_tasks_control_idx on public.casa_pair_tasks(control_id);
create index casa_pair_tasks_assignee_idx on public.casa_pair_tasks(assignee_id);
create table public.casa_pair_absences (
 id uuid primary key default gen_random_uuid(),control_id uuid not null references public.casa_pair_controls(id),member_id uuid not null references public.casa_members(id),
 starts_on date not null,ends_on date,reason text not null default '' check(length(reason)<=200),created_at timestamptz not null default now(),check(ends_on is null or ends_on>=starts_on)
);
create index casa_pair_absence_control_idx on public.casa_pair_absences(control_id);
create index casa_pair_absence_member_idx on public.casa_pair_absences(member_id);
create table public.casa_pair_completions (
 id uuid primary key default gen_random_uuid(),control_id uuid not null references public.casa_pair_controls(id),task_id uuid not null,
 task_title text not null,occurrence_date date not null,original_member_id uuid not null references public.casa_members(id),completed_by uuid not null references public.casa_members(id),
 exempt boolean not null default false,completed_at timestamptz not null default now(),unique(task_id,occurrence_date),foreign key(task_id,control_id)references public.casa_pair_tasks(id,control_id)
);
create index casa_pair_completion_control_idx on public.casa_pair_completions(control_id);
create index casa_pair_completion_task_idx on public.casa_pair_completions(task_id,control_id);
create index casa_pair_completion_original_idx on public.casa_pair_completions(original_member_id);
create index casa_pair_completion_actual_idx on public.casa_pair_completions(completed_by);
create function public.casa_pair_can_access(p_control uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.casa_pair_controls g join public.casa_members m on m.id in(g.member_a,g.member_b) and m.household_id=g.household_id where g.id=p_control and m.user_id=(select auth.uid()))
$$;
create function casa_private.pair_context(p_control uuid) returns public.casa_pair_controls language plpgsql stable security definer set search_path='' as $$
declare g public.casa_pair_controls;
begin
 if auth.uid() is null or not public.casa_pair_can_access(p_control) then raise exception 'Controle indisponível.';end if;
 select * into g from public.casa_pair_controls where id=p_control;return g;
end $$;
alter table public.casa_pair_controls enable row level security;
alter table public.casa_pair_tasks enable row level security;
alter table public.casa_pair_absences enable row level security;
alter table public.casa_pair_completions enable row level security;
create policy pair_control_read on public.casa_pair_controls for select to authenticated using(public.casa_pair_can_access(id));
create policy pair_task_read on public.casa_pair_tasks for select to authenticated using(public.casa_pair_can_access(control_id));
create policy pair_absence_read on public.casa_pair_absences for select to authenticated using(public.casa_pair_can_access(control_id));
create policy pair_completion_read on public.casa_pair_completions for select to authenticated using(public.casa_pair_can_access(control_id));
revoke all on public.casa_pair_controls,public.casa_pair_tasks,public.casa_pair_absences,public.casa_pair_completions from anon,authenticated;
grant select on public.casa_pair_controls,public.casa_pair_tasks,public.casa_pair_absences,public.casa_pair_completions to authenticated;
create function public.casa_pair_list() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(g order by g.created_at),'[]'::jsonb) from public.casa_pair_controls g where public.casa_pair_can_access(g.id)
$$;
create function public.casa_pair_snapshot(p_control uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);h public.casa_households;
begin
 select * into h from public.casa_households where id=g.household_id;
 return jsonb_build_object('scope','pair','control_id',g.id,
 'household',jsonb_build_object('id',h.id,'name',g.name,'timezone',h.timezone,'owner_id',g.created_by),
 'members',(select jsonb_agg(m order by m.created_at,m.id) from public.casa_members m where m.id in(g.member_a,g.member_b)),
 'tasks',coalesce((select jsonb_agg(t order by t.due_time,t.id) from public.casa_pair_tasks t where t.control_id=g.id),'[]'::jsonb),
 'absences',coalesce((select jsonb_agg(a order by a.starts_on) from public.casa_pair_absences a where a.control_id=g.id),'[]'::jsonb),
 'completions',coalesce((select jsonb_agg(c order by c.completed_at desc) from public.casa_pair_completions c where c.control_id=g.id),'[]'::jsonb),'settlements','[]'::jsonb);
end $$;
create function public.casa_pair_create(p_name text,p_other uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();m uuid;g uuid;
begin
 select id into m from public.casa_members where user_id=auth.uid();
 if h is null or m=p_other or not exists(select 1 from public.casa_members where id=p_other and household_id=h) then raise exception 'Escolha outro morador da sua casa.';end if;
 insert into public.casa_pair_controls(household_id,name,member_a,member_b,created_by)values(h,trim(p_name),m,p_other,auth.uid())returning id into g;
 return jsonb_build_object('id',g);
end $$;

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
 where t.control_id=p_control and
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
 where t.control_id=p_control and
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



create function public.casa_pair_save_task(p_control uuid,p_task jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);tid uuid:=(p_task->>'id')::uuid;assignee uuid:=(p_task->>'assignee_id')::uuid;
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 if assignee not in(g.member_a,g.member_b) then raise exception 'Participante inválido.';end if;
 if tid is null then
 insert into public.casa_pair_tasks(control_id,title,emoji,assignee_id,starts_on,due_time,recurrence,interval_days,duration_minutes)
 values(g.id,trim(p_task->>'title'),p_task->>'emoji',assignee,(p_task->>'starts_on')::date,(p_task->>'due_time')::time,p_task->>'recurrence',coalesce((p_task->>'interval_days')::integer,1),(p_task->>'duration_minutes')::integer);
 else
 update public.casa_pair_tasks set title=trim(p_task->>'title'),emoji=p_task->>'emoji',assignee_id=assignee,starts_on=(p_task->>'starts_on')::date,due_time=(p_task->>'due_time')::time,recurrence=p_task->>'recurrence',interval_days=coalesce((p_task->>'interval_days')::integer,1),duration_minutes=(p_task->>'duration_minutes')::integer,active=coalesce((p_task->>'active')::boolean,true) where id=tid and control_id=g.id;
 if not found then raise exception 'Tarefa indisponível.';end if;
 end if;return public.casa_pair_snapshot(g.id);
end $$;
create function public.casa_pair_archive_task(p_control uuid,p_task_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);
begin
 update public.casa_pair_tasks set active=false where id=p_task_id and control_id=g.id;
 if not found then raise exception 'Tarefa indisponível.';end if;return public.casa_pair_snapshot(g.id);
end $$;
create function public.casa_pair_save_absence(p_control uuid,p_member_id uuid,p_start date,p_end date default null,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 if p_member_id not in(g.member_a,g.member_b) then raise exception 'Participante inválido.';end if;
 insert into public.casa_pair_absences(control_id,member_id,starts_on,ends_on,reason)values(g.id,p_member_id,p_start,p_end,p_reason);
 return public.casa_pair_snapshot(g.id);
end $$;
create function public.casa_pair_end_absence(p_control uuid,p_absence_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);d date;
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 select (now() at time zone timezone)::date into d from public.casa_households where id=g.household_id;
 update public.casa_pair_absences set ends_on=d-1 where id=p_absence_id and control_id=g.id and starts_on<d;
 if not found then delete from public.casa_pair_absences where id=p_absence_id and control_id=g.id and starts_on>=d;end if;
 return public.casa_pair_snapshot(g.id);
end $$;
create function public.casa_pair_complete_task(p_control uuid,p_task_id uuid,p_date date,p_expected_member uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);m uuid;t public.casa_pair_tasks;d date;assigned uuid;
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 select id into m from public.casa_members where user_id=auth.uid();
 select * into t from public.casa_pair_tasks where id=p_task_id and control_id=g.id for update;
 if t.id is null or not t.active then raise exception 'Tarefa indisponível.';end if;
 select (now() at time zone timezone)::date into d from public.casa_households where id=g.household_id;
 if p_date>d or not casa_private.is_due(t.recurrence,t.starts_on,t.interval_days,p_date) then raise exception 'Data inválida para esta tarefa.';end if;
 if exists(select 1 from public.casa_pair_absences where control_id=g.id and member_id=m and starts_on<=p_date and (ends_on is null or ends_on>=p_date)) then raise exception 'Encerre a ausência neste controle antes de realizar tarefas.';end if;
 select effective_member_id into assigned from casa_private.pair_assignments(g.id,p_date)where task_id=t.id;
 if assigned is null or p_expected_member is distinct from assigned then raise exception 'O rodízio mudou. Atualize a lista antes de concluir.';end if;
 insert into public.casa_pair_completions(control_id,task_id,task_title,occurrence_date,original_member_id,completed_by)values(g.id,t.id,t.title,p_date,assigned,m);
 return public.casa_pair_snapshot(g.id);
exception when unique_violation then raise exception 'Esta tarefa já foi concluída. Atualize a lista.';
end $$;
create function public.casa_pair_undo_completion(p_control uuid,p_completion_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.casa_pair_controls:=casa_private.pair_context(p_control);m uuid;
begin
 perform 1 from public.casa_pair_controls where id=g.id for update;
 select id into m from public.casa_members where user_id=auth.uid();
 delete from public.casa_pair_completions where id=p_completion_id and control_id=g.id and (completed_by=m or g.created_by=auth.uid());
 if not found then raise exception 'Conclusão indisponível ou sem permissão para desfazer.';end if;return public.casa_pair_snapshot(g.id);
end $$;
do $$ declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'casa_pair_%' loop
 execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
revoke all on all functions in schema casa_private from public,anon,authenticated;
