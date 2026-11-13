create index if not exists casa_completion_rotation_idx on public.casa_completions(household_id,task_id,completed_by,occurrence_date,completed_at desc);
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
 where t.household_id=p_household and
 ((t.active and work_date>=t.starts_on and (t.recurrence='daily' or (t.recurrence='once' and work_date=t.starts_on) or (t.recurrence='weekly' and (work_date-t.starts_on)%7=0)))
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
