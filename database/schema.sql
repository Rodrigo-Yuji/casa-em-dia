create schema if not exists casa_private;
revoke all on schema casa_private from public, anon, authenticated;
create table public.casa_households (
 id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 80),
 owner_id uuid not null references auth.users(id), invite_code uuid not null unique default gen_random_uuid(),
 timezone text not null default 'America/Sao_Paulo', created_at timestamptz not null default now()
);
create table public.casa_members (
 id uuid primary key default gen_random_uuid(), household_id uuid not null references public.casa_households(id),
 user_id uuid unique references auth.users(id), name text not null check(length(name) between 1 and 60),
 created_at timestamptz not null default now(), unique(id,household_id)
);
create index casa_members_household_idx on public.casa_members(household_id);
create table public.casa_tasks (
 id uuid primary key default gen_random_uuid(), household_id uuid not null references public.casa_households(id),
 title text not null check(length(title) between 1 and 120), emoji text not null default '🧹' check(length(emoji)<20),
 assignee_id uuid not null, starts_on date not null, due_time time not null default '18:00',
 recurrence text not null default 'daily' check(recurrence in ('daily','weekly','once')),
 duration_minutes integer not null default 10 check(duration_minutes between 1 and 360),
 active boolean not null default true, created_at timestamptz not null default now(),
 unique(id,household_id), foreign key(assignee_id,household_id) references public.casa_members(id,household_id)
);
create index casa_tasks_household_idx on public.casa_tasks(household_id);
create index casa_tasks_assignee_idx on public.casa_tasks(assignee_id,household_id);
create table public.casa_absences (
 id uuid primary key default gen_random_uuid(), household_id uuid not null references public.casa_households(id),
 member_id uuid not null, starts_on date not null, ends_on date, reason text not null default '' check(length(reason)<=200),
 created_at timestamptz not null default now(), check(ends_on is null or ends_on>=starts_on),
 foreign key(member_id,household_id) references public.casa_members(id,household_id)
);
create index casa_absences_household_idx on public.casa_absences(household_id);
create index casa_absences_member_idx on public.casa_absences(member_id,household_id);
create table public.casa_completions (
 id uuid primary key default gen_random_uuid(), household_id uuid not null references public.casa_households(id),
 task_id uuid not null, task_title text not null, occurrence_date date not null,
 original_member_id uuid not null, completed_by uuid not null, exempt boolean not null default false,
 completed_at timestamptz not null default now(), unique(task_id,occurrence_date),
 foreign key(task_id,household_id) references public.casa_tasks(id,household_id),
 foreign key(original_member_id,household_id) references public.casa_members(id,household_id),
 foreign key(completed_by,household_id) references public.casa_members(id,household_id)
);
create index casa_completions_household_idx on public.casa_completions(household_id);
create index casa_completions_original_idx on public.casa_completions(original_member_id,household_id);
create index casa_completions_completed_idx on public.casa_completions(completed_by,household_id);
create table public.casa_settlements (
 id uuid primary key default gen_random_uuid(), household_id uuid not null references public.casa_households(id),
 from_member_id uuid not null, to_member_id uuid not null, quantity integer not null check(quantity>0),
 created_at timestamptz not null default now(), check(from_member_id<>to_member_id),
 foreign key(from_member_id,household_id) references public.casa_members(id,household_id),
 foreign key(to_member_id,household_id) references public.casa_members(id,household_id)
);
create index casa_settlements_household_idx on public.casa_settlements(household_id);
create index casa_settlements_from_idx on public.casa_settlements(from_member_id,household_id);
create index casa_settlements_to_idx on public.casa_settlements(to_member_id,household_id);

create function public.casa_my_household() returns uuid language sql stable security definer set search_path = '' as $$
 select household_id from public.casa_members where user_id=(select auth.uid())
$$;
revoke all on function public.casa_my_household() from public,anon;
grant execute on function public.casa_my_household() to authenticated;
alter table public.casa_households enable row level security;
alter table public.casa_members enable row level security;
alter table public.casa_tasks enable row level security;
alter table public.casa_absences enable row level security;
alter table public.casa_completions enable row level security;
alter table public.casa_settlements enable row level security;
create policy household_read on public.casa_households for select to authenticated using(id=(select public.casa_my_household()));
create policy member_read on public.casa_members for select to authenticated using(household_id=(select public.casa_my_household()));
create policy task_read on public.casa_tasks for select to authenticated using(household_id=(select public.casa_my_household()));
create policy absence_read on public.casa_absences for select to authenticated using(household_id=(select public.casa_my_household()));
create policy completion_read on public.casa_completions for select to authenticated using(household_id=(select public.casa_my_household()));
create policy settlement_read on public.casa_settlements for select to authenticated using(household_id=(select public.casa_my_household()));
revoke all on public.casa_households,public.casa_members,public.casa_tasks,public.casa_absences,public.casa_completions,public.casa_settlements from anon,authenticated;
grant select on public.casa_households,public.casa_members,public.casa_tasks,public.casa_absences,public.casa_completions,public.casa_settlements to authenticated;

create function public.casa_snapshot() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if h is null then return null; end if;
 return jsonb_build_object(
 'household',(select to_jsonb(x) from public.casa_households x where id=h),
 'members',coalesce((select jsonb_agg(x order by created_at) from public.casa_members x where household_id=h),'[]'::jsonb),
 'tasks',coalesce((select jsonb_agg(x order by due_time) from public.casa_tasks x where household_id=h),'[]'::jsonb),
 'absences',coalesce((select jsonb_agg(x order by starts_on) from public.casa_absences x where household_id=h),'[]'::jsonb),
 'completions',coalesce((select jsonb_agg(x order by completed_at desc) from public.casa_completions x where household_id=h),'[]'::jsonb),
 'settlements',coalesce((select jsonb_agg(x order by created_at desc) from public.casa_settlements x where household_id=h),'[]'::jsonb));
end $$;

create function public.casa_create_household(p_name text,p_person_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid; m uuid; d date:=(now() at time zone 'America/Sao_Paulo')::date;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if public.casa_my_household() is not null then raise exception 'Você já faz parte de uma casa.'; end if;
 insert into public.casa_households(name,owner_id) values(trim(p_name),auth.uid()) returning id into h;
 insert into public.casa_members(household_id,user_id,name) values(h,auth.uid(),trim(p_person_name)) returning id into m;
 insert into public.casa_tasks(household_id,title,emoji,assignee_id,starts_on,due_time,duration_minutes) values
 (h,'Limpar a areia dos gatos','🐈',m,d,'08:00',5),(h,'Preparar a lava-louças','🍽️',m,d,'20:00',10);
 insert into public.casa_tasks(household_id,title,emoji,assignee_id,starts_on,due_time,recurrence,duration_minutes) values
 (h,'Lavar roupa','🧺',m,d,'10:00','weekly',30);
 return public.casa_snapshot();
end $$;

create function public.casa_invite_preview(p_code uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare h uuid; n text;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select id,name into h,n from public.casa_households where invite_code=p_code;
 if h is null then raise exception 'Código de convite inválido.'; end if;
 return jsonb_build_object('name',n,'members',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)) from public.casa_members where household_id=h and user_id is null),'[]'::jsonb));
end $$;
create function public.casa_join_household(p_code uuid,p_person_name text,p_claim_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid; claimed uuid;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if public.casa_my_household() is not null then raise exception 'Você já faz parte de uma casa.'; end if;
 select id into h from public.casa_households where invite_code=p_code for update;
 if h is null then raise exception 'Código de convite inválido.'; end if;
 if p_claim_id is not null then
  update public.casa_members set user_id=auth.uid() where id=p_claim_id and household_id=h and user_id is null returning id into claimed;
  if claimed is null then raise exception 'Esta pessoa já vinculou uma conta. Escolha outro perfil.'; end if;
 else
  insert into public.casa_members(household_id,user_id,name) values(h,auth.uid(),trim(p_person_name));
 end if;
 return public.casa_snapshot();
end $$;
create function public.casa_add_member(p_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 insert into public.casa_members(household_id,name) values(h,trim(p_name));
 return public.casa_snapshot();
end $$;
create function public.casa_save_task(p_task jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household(); tid uuid:=(p_task->>'id')::uuid;
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 if tid is null then
  insert into public.casa_tasks(household_id,title,emoji,assignee_id,starts_on,due_time,recurrence,duration_minutes)
  values(h,trim(p_task->>'title'),p_task->>'emoji',(p_task->>'assignee_id')::uuid,(p_task->>'starts_on')::date,
  (p_task->>'due_time')::time,p_task->>'recurrence',(p_task->>'duration_minutes')::integer);
 else
  update public.casa_tasks set title=trim(p_task->>'title'),emoji=p_task->>'emoji',assignee_id=(p_task->>'assignee_id')::uuid,
  starts_on=(p_task->>'starts_on')::date,due_time=(p_task->>'due_time')::time,recurrence=p_task->>'recurrence',
  duration_minutes=(p_task->>'duration_minutes')::integer,active=coalesce((p_task->>'active')::boolean,true)
  where id=tid and household_id=h;
  if not found then raise exception 'Tarefa não encontrada.'; end if;
 end if;
 return public.casa_snapshot();
end $$;
create function public.casa_archive_task(p_task_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 update public.casa_tasks set active=false where id=p_task_id and household_id=public.casa_my_household();
 if not found then raise exception 'Tarefa não encontrada.'; end if;
 return public.casa_snapshot();
end $$;

create function public.casa_save_absence(p_member_id uuid,p_start date,p_end date default null,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 insert into public.casa_absences(household_id,member_id,starts_on,ends_on,reason) values(h,p_member_id,p_start,p_end,p_reason);
 return public.casa_snapshot();
end $$;
create function public.casa_end_absence(p_absence_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household(); d date;
begin
 select (now() at time zone timezone)::date into d from public.casa_households where id=h;
 -- End yesterday so the member becomes available again today.
 update public.casa_absences set ends_on=d-1 where id=p_absence_id and household_id=h and starts_on<d;
 if not found then
  delete from public.casa_absences where id=p_absence_id and household_id=h and starts_on>=d;
 end if;
 return public.casa_snapshot();
end $$;

create function public.casa_complete_task(p_task_id uuid,p_date date) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household(); m uuid; t public.casa_tasks; d date; exc boolean;
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 select id into m from public.casa_members where user_id=auth.uid() and household_id=h;
 select * into t from public.casa_tasks where id=p_task_id and household_id=h for update;
 if t.id is null or not t.active then raise exception 'Tarefa indisponível.'; end if;
 select (now() at time zone timezone)::date into d from public.casa_households where id=h;
 if p_date>d or p_date<t.starts_on or (t.recurrence='once' and p_date<>t.starts_on)
 or (t.recurrence='weekly' and (p_date-t.starts_on)%7<>0) then raise exception 'Data inválida para esta tarefa.'; end if;
 if exists(select 1 from public.casa_absences where member_id=m and starts_on<=p_date and (ends_on is null or ends_on>=p_date)) then
 raise exception 'Encerre sua ausência antes de realizar tarefas.'; end if;
 select exists(select 1 from public.casa_absences where member_id=t.assignee_id and starts_on<=p_date and (ends_on is null or ends_on>=p_date)) into exc;
 insert into public.casa_completions(household_id,task_id,task_title,occurrence_date,original_member_id,completed_by,exempt)
 values(h,t.id,t.title,p_date,t.assignee_id,m,exc);
 return public.casa_snapshot();
exception when unique_violation then raise exception 'Alguém já concluiu esta tarefa. Atualize a lista.';
end $$;
create function public.casa_undo_completion(p_completion_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 delete from public.casa_completions c where c.id=p_completion_id and c.household_id=h and
 (c.completed_by=(select id from public.casa_members where user_id=auth.uid()) or
 exists(select 1 from public.casa_households where id=h and owner_id=auth.uid()));
 if not found then raise exception 'Só quem concluiu ou criou a casa pode desfazer.'; end if;
 return public.casa_snapshot();
end $$;

create function public.casa_settle_favors(p_to uuid,p_quantity integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household(); m uuid; owed bigint;
begin
 if h is null or p_quantity<1 then raise exception 'Quantidade inválida.'; end if;
 perform 1 from public.casa_households where id=h for update;
 select id into m from public.casa_members where user_id=auth.uid();
 if not exists(select 1 from public.casa_members where id=p_to and household_id=h) or p_to=m then raise exception 'Pessoa inválida.'; end if;
 select coalesce(sum(case when original_member_id=m and completed_by=p_to then 1 when original_member_id=p_to and completed_by=m then -1 else 0 end),0)
 into owed from public.casa_completions where household_id=h and not exempt;
 owed:=owed-coalesce((select sum(case when from_member_id=m and to_member_id=p_to then quantity when from_member_id=p_to and to_member_id=m then -quantity else 0 end) from public.casa_settlements where household_id=h),0);
 if p_quantity>owed then raise exception 'O saldo mudou. Atualize antes de quitar.'; end if;
 insert into public.casa_settlements(household_id,from_member_id,to_member_id,quantity) values(h,m,p_to,p_quantity);
 return public.casa_snapshot();
end $$;

-- All state changes go through scoped RPCs; no unauthenticated execution.
do $$
declare f record;
begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'casa_%'
 loop
 execute format('revoke all on function %s from public, anon',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
