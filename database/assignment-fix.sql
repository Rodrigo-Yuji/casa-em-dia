create or replace function casa_private.assignments(p_household uuid,p_date date)
returns table(task_id uuid,effective_member_id uuid,redistributed boolean)
language plpgsql stable security definer set search_path='' as $$
declare
 members uuid[]; loads integer[]; counts integer[]; rec record; idx integer; best integer; n integer; assigned uuid;
begin
 select array_agg(m.id order by m.id) into members from public.casa_members m
 where m.household_id=p_household and not exists(select 1 from public.casa_absences a where a.member_id=m.id and a.starts_on<=p_date and (a.ends_on is null or a.ends_on>=p_date));
 n:=coalesce(array_length(members,1),0);
 loads:=array_fill(0,array[n]); counts:=array_fill(0,array[n]);
 -- Fixed assignments and completed occurrences establish the day's existing load.
 for rec in select t.*,c.original_member_id as locked_member from public.casa_tasks t
 left join public.casa_completions c on c.task_id=t.id and c.occurrence_date=p_date
 where t.household_id=p_household and (t.active or c.id is not null)
 and (c.id is not null or (p_date>=t.starts_on and (t.recurrence='daily' or (t.recurrence='once' and p_date=t.starts_on) or (t.recurrence='weekly' and (p_date-t.starts_on)%7=0))))
 order by t.id loop
 assigned:=coalesce(rec.locked_member,rec.assignee_id);
 idx:=array_position(members,assigned);
 if rec.locked_member is not null or idx is not null then
  if idx is not null then loads[idx]:=loads[idx]+rec.duration_minutes; counts[idx]:=counts[idx]+1; end if;
  task_id:=rec.id; effective_member_id:=assigned; redistributed:=assigned<>rec.assignee_id; return next;
 end if;
 end loop;
 -- Longest tasks first reduces imbalance. Stable IDs break exact ties.
 for rec in select t.* from public.casa_tasks t
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
  loads[best]:=loads[best]+rec.duration_minutes; counts[best]:=counts[best]+1;
 end if;
 task_id:=rec.id; effective_member_id:=case when best is null then null else members[best] end;
 redistributed:=true; return next;
 end loop;
end $$;
