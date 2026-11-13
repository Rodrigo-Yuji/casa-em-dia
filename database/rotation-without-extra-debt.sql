create index if not exists casa_completion_rotation_idx on public.casa_completions(household_id,task_id,completed_by,occurrence_date,completed_at desc);
create or replace function casa_private.assignments(p_household uuid,p_date date)
returns table(task_id uuid,effective_member_id uuid,redistributed boolean)
language plpgsql stable security definer set search_path='' as $$
declare
 today_date date; start_date date; work_date date; rec record; member_rec record; done public.casa_completions;
 last_done jsonb:='{}'::jsonb; deferred jsonb:='{}'::jsonb; day_load jsonb; day_count jsonb;
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
 -- Reserve completed work first, so other tasks consider the work actually performed.
 for rec in select c.completed_by,sum(t.duration_minutes)::integer as mins,count(*)::integer as amount
 from public.casa_completions c join public.casa_tasks t on t.id=c.task_id
 where c.household_id=p_household and c.occurrence_date=work_date group by c.completed_by loop
 day_load:=jsonb_set(day_load,array[rec.completed_by::text],to_jsonb(rec.mins));
 day_count:=jsonb_set(day_count,array[rec.completed_by::text],to_jsonb(rec.amount));
 end loop;
 for rec in select t.* from public.casa_tasks t
 where t.household_id=p_household and
 ((t.active and work_date>=t.starts_on and (t.recurrence='daily' or (t.recurrence='once' and work_date=t.starts_on) or (t.recurrence='weekly' and (work_date-t.starts_on)%7=0)))
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
 chosen_rank:=null;best_hold:=null;best_load:=null;best_count:=null;
 for member_rec in select m.* from public.casa_members m where m.household_id=p_household
 and not exists(select 1 from public.casa_absences a where a.member_id=m.id and a.starts_on<=work_date and (a.ends_on is null or a.ends_on>=work_date))
 order by (m.id=rec.assignee_id) desc,m.id loop
 member_key:=member_rec.id::text;
 candidate_rank:=case when deferred ? (task_key||':'||member_key) then -2 else coalesce((last_done->>(task_key||':'||member_key))::numeric,-1) end;
 candidate_hold:=coalesce((deferred->>(task_key||':'||member_key))::numeric,0);
 candidate_load:=coalesce((day_load->>member_key)::integer,0);
 candidate_count:=coalesce((day_count->>member_key)::integer,0);
 if chosen is null or candidate_rank<chosen_rank or
 (candidate_rank=chosen_rank and (candidate_hold<best_hold or (candidate_hold=best_hold and (candidate_load<best_load or (candidate_load=best_load and candidate_count<best_count))))) then
 chosen:=member_rec.id;chosen_rank:=candidate_rank;best_hold:=candidate_hold;best_load:=candidate_load;best_count:=candidate_count;
 end if;
 end loop;
 if chosen is not null then
 member_key:=chosen::text;tick:=tick+1;
 last_done:=jsonb_set(last_done,array[task_key||':'||member_key],to_jsonb(tick));
 deferred:=deferred-(task_key||':'||member_key);
 day_load:=jsonb_set(day_load,array[member_key],to_jsonb(coalesce((day_load->>member_key)::integer,0)+rec.duration_minutes));
 day_count:=jsonb_set(day_count,array[member_key],to_jsonb(coalesce((day_count->>member_key)::integer,0)+1));
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


-- Coverage changes turns, never creates a second obligation.
create or replace function public.casa_archive_task(p_task_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h uuid:=public.casa_my_household();
begin
 if h is null then raise exception 'Entre em uma casa.';end if;
 perform 1 from public.casa_households where id=h for update;
 update public.casa_tasks set active=false where id=p_task_id and household_id=h;
 if not found then raise exception 'Tarefa não encontrada.';end if;
 return public.casa_snapshot();
end $$;
create or replace function public.casa_settle_favors(p_to uuid,p_quantity integer) returns jsonb language plpgsql security definer set search_path='' as $$
begin raise exception 'A compensação acontece apenas pelo rodízio, sem dívida extra.';end $$;
revoke all on function public.casa_settle_favors(uuid,integer) from public,anon,authenticated;
revoke all on all functions in schema casa_private from public,anon,authenticated;
