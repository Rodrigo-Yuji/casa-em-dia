begin;
do $test$
declare ua uuid:=gen_random_uuid();ub uuid:=gen_random_uuid();h uuid;a uuid;b uuid;target uuid;completion uuid;
 d date:=(now() at time zone 'America/Sao_Paulo')::date; before_today jsonb; before_next jsonb; after_plan jsonb; item record;
begin
 insert into auth.users(id,email)values(ua,'isolation-a-'||ua||'@example.invalid'),(ub,'isolation-b-'||ub||'@example.invalid');
 perform set_config('request.jwt.claim.sub',ua::text,true);
 perform public.casa_create_household('Task isolation test','A');h:=public.casa_my_household();
 select id into a from public.casa_members where user_id=ua;
 perform public.casa_add_member('B');select id into b from public.casa_members where household_id=h and name='B';
 update public.casa_members set user_id=ub where id=b;
 update public.casa_tasks set duration_minutes=10,recurrence='daily',starts_on=d,assignee_id=a where household_id=h;
 select jsonb_object_agg(task_id,effective_member_id) into before_today from casa_private.assignments(h,d);
 select jsonb_object_agg(task_id,effective_member_id) into before_next from casa_private.assignments(h,d+1);
 if (select count(*) from casa_private.assignments(h,d) where effective_member_id=a)<>2 then raise exception 'Fixture must give A two tasks';end if;
 select task_id into target from casa_private.assignments(h,d) where effective_member_id=b;
 if target is null then raise exception 'Fixture must give B one task';end if;
 perform public.casa_complete_task(target,d,b);
 select jsonb_object_agg(task_id,effective_member_id) into after_plan from casa_private.assignments(h,d);
 for item in select key,value from jsonb_each(before_today) where key<>target::text loop
 if after_plan->item.key is distinct from item.value then raise exception 'FAIL: coverage moved an unrelated duty today';end if;
 end loop;
 select jsonb_object_agg(task_id,effective_member_id) into after_plan from casa_private.assignments(h,d+1);
 for item in select key,value from jsonb_each(before_next) where key<>target::text loop
 if after_plan->item.key is distinct from item.value then raise exception 'FAIL: coverage moved an unrelated future duty';end if;
 end loop;
 if after_plan->>target::text<>b::text then raise exception 'FAIL: covered person lost next turn';end if;
 select id into completion from public.casa_completions where task_id=target and occurrence_date=d;
 perform public.casa_undo_completion(completion);
 select jsonb_object_agg(task_id,effective_member_id) into after_plan from casa_private.assignments(h,d);
 if after_plan is distinct from before_today then raise exception 'FAIL: undo changed the initial allocation';end if;
 -- Absences are still an explicit, legitimate reason for redistribution.
 perform public.casa_save_absence(b,d,null,'Viagem');
 if exists(select 1 from casa_private.assignments(h,d) where effective_member_id=b) then raise exception 'FAIL: absence no longer redistributes';end if;
end $test$;
select 'PASS: A keeps both tasks after covering B; unrelated tasks unchanged today and tomorrow; covered task keeps B next; undo is stable; absences still redistribute' as result;
rollback;
