create function casa_private.assignments(p_household uuid,p_date date)
returns table(task_id uuid,effective_member_id uuid,redistributed boolean)
language plpgsql stable security definer set search_path='' as $$
declare
 members uuid[]; loads integer[]; counts integer[]; t record; idx integer; best integer; n integer; assigned uuid;
begin
 select array_agg(m.id order by m.id) into members from public.casa_members m
 where m.household_id=p_household and not exists(select 1 from public.casa_absences a where a.member_id=m.id and a.starts_on<=p_date and (a.ends_on is null or a.ends_on>=p_date));
 n:=coalesce(array_length(members,1),0);
 loads:=array_fill(0,array[n]); counts:=array_fill(0,array[n]);
 -- Fixed assignments and completed occurrences establish the day's existing load.
 for t in select t.*,c.original_member_id as locked_member from public.casa_tasks t
 left join public.casa_completions c on c.task_id=t.id and c.occurrence_date=p_date
 where t.household_id=p_household and (t.active or c.id is not null)
 and p_date>=t.starts_on and (t.recurrence='daily' or (t.recurrence='once' and p_date=t.starts_on) or (t.recurrence='weekly' and (p_date-t.starts_on)%7=0))
 order by t.id loop
 assigned:=coalesce(t.locked_member,t.assignee_id);
 idx:=array_position(members,assigned);
 if t.locked_member is not null or idx is not null then
  if idx is not null then loads[idx]:=loads[idx]+t.duration_minutes; counts[idx]:=counts[idx]+1; end if;
  task_id:=t.id; effective_member_id:=assigned; redistributed:=assigned<>t.assignee_id; return next;
 end if;
 end loop;
 -- Longest tasks first reduces imbalance. Stable IDs break exact ties.
 for t in select t.* from public.casa_tasks t
 where t.household_id=p_household and t.active and p_date>=t.starts_on
 and (t.recurrence='daily' or (t.recurrence='once' and p_date=t.starts_on) or (t.recurrence='weekly' and (p_date-t.starts_on)%7=0))
 and not exists(select 1 from public.casa_completions c where c.task_id=t.id and c.occurrence_date=p_date)
 and not (t.assignee_id=any(coalesce(members,'{}'::uuid[])))
 order by t.duration_minutes desc,t.id loop
 best:=null;
 if n>0 then
  for idx in 1..n loop
   if best is null or loads[idx]<loads[best] or (loads[idx]=loads[best] and counts[idx]<counts[best]) then best:=idx; end if;
  end loop;
  loads[best]:=loads[best]+t.duration_minutes; counts[best]:=counts[best]+1;
 end if;
 task_id:=t.id; effective_member_id:=case when best is null then null else members[best] end;
 redistributed:=true; return next;
 end loop;
end $$;
create function public.casa_assignments(p_date date) returns table(task_id uuid,effective_member_id uuid,redistributed boolean)
language sql stable security definer set search_path='' as $$
 select * from casa_private.assignments(public.casa_my_household(),p_date)
$$;
revoke all on function public.casa_assignments(date) from public,anon;
grant execute on function public.casa_assignments(date) to authenticated;

create or replace function public.casa_complete_task(p_task_id uuid,p_date date) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household(); m uuid; t public.casa_tasks; d date; assigned uuid;
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 -- Serialize completions/absence changes so responsibility is captured atomically.
 perform 1 from public.casa_households where id=h for update;
 select id into m from public.casa_members where user_id=auth.uid() and household_id=h;
 select * into t from public.casa_tasks where id=p_task_id and household_id=h for update;
 if t.id is null or not t.active then raise exception 'Tarefa indisponível.'; end if;
 select (now() at time zone timezone)::date into d from public.casa_households where id=h;
 if p_date>d or p_date<t.starts_on or (t.recurrence='once' and p_date<>t.starts_on)
 or (t.recurrence='weekly' and (p_date-t.starts_on)%7<>0) then raise exception 'Data inválida para esta tarefa.'; end if;
 if exists(select 1 from public.casa_absences where member_id=m and starts_on<=p_date and (ends_on is null or ends_on>=p_date)) then
 raise exception 'Encerre sua ausência antes de realizar tarefas.'; end if;
 select effective_member_id into assigned from casa_private.assignments(h,p_date) where task_id=p_task_id;
 if assigned is null then raise exception 'Não há morador disponível nesta data.'; end if;
 insert into public.casa_completions(household_id,task_id,task_title,occurrence_date,original_member_id,completed_by,exempt)
 values(h,t.id,t.title,p_date,assigned,m,false);
 return public.casa_snapshot();
exception when unique_violation then raise exception 'Alguém já concluiu esta tarefa. Atualize a lista.';
end $$;
create or replace function public.casa_save_absence(p_member_id uuid,p_start date,p_end date default null,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 if h is null then raise exception 'Entre em uma casa.'; end if;
 perform 1 from public.casa_households where id=h for update;
 insert into public.casa_absences(household_id,member_id,starts_on,ends_on,reason) values(h,p_member_id,p_start,p_end,p_reason);
 return public.casa_snapshot();
end $$;
revoke all on all functions in schema casa_private from public,anon,authenticated;
