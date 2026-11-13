-- Run only after the three feature SQL scripts, inside a transaction with rollback.
begin;
do $test$
declare u1 uuid:=gen_random_uuid();u2 uuid:=gen_random_uuid();u3 uuid:=gen_random_uuid();h uuid;m1 uuid;m2 uuid;m3 uuid;g uuid;tid uuid;d date:=(now()at time zone 'America/Sao_Paulo')::date;before_shared jsonb;after_shared jsonb;assigned uuid;
begin
 insert into auth.users(id,email)values(u1,'private-a-'||u1||'@example.invalid'),(u2,'private-b-'||u2||'@example.invalid'),(u3,'private-c-'||u3||'@example.invalid');
 perform set_config('request.jwt.claim.sub',u1::text,true);perform public.casa_create_household('Private feature test','A');h:=public.casa_my_household();
 select id into m1 from public.casa_members where user_id=u1;perform public.casa_add_member('B');perform public.casa_add_member('C');
 select id into m2 from public.casa_members where household_id=h and name='B';select id into m3 from public.casa_members where household_id=h and name='C';
 update public.casa_members set user_id=u2 where id=m2;update public.casa_members set user_id=u3 where id=m3;
 select jsonb_agg(x order by x.task_id)into before_shared from casa_private.assignments(h,d)x;
 g:=(public.casa_pair_create('Só A e B',m2)->>'id')::uuid;
 perform public.casa_pair_save_task(g,jsonb_build_object('title','Tarefa privada','emoji','🌿','assignee_id',m1,'starts_on',d-4,'due_time','18:00','recurrence','interval','interval_days',2,'duration_minutes',10));
 select id into tid from public.casa_pair_tasks where control_id=g;
 if exists(select 1 from casa_private.pair_assignments(g,d-3))then raise exception 'FAIL: interval task appears on wrong date';end if;
 if not exists(select 1 from casa_private.pair_assignments(g,d))then raise exception 'FAIL: interval task missing on due date';end if;
 select effective_member_id into assigned from casa_private.pair_assignments(g,d)where task_id=tid;
 perform public.casa_pair_complete_task(g,tid,d,assigned);
 select jsonb_agg(x order by x.task_id)into after_shared from casa_private.assignments(h,d)x;
 if before_shared is distinct from after_shared then raise exception 'FAIL: private completion affected household rotation';end if;
 if jsonb_array_length(public.casa_pair_snapshot(g)->'members')<>2 then raise exception 'FAIL: incorrect private participants';end if;
 perform public.casa_pair_save_absence(g,m1,d,null,'Ausência privada');
 if exists(select 1 from public.casa_absences where household_id=h)then raise exception 'FAIL: private absence leaked into shared control';end if;
 perform set_config('request.jwt.claim.sub',u3::text,true);
 if public.casa_pair_list()<>'[]'::jsonb then raise exception 'FAIL: third user can list private controls';end if;
 if public.casa_pair_can_access(g)then raise exception 'FAIL: third user has private access';end if;
 begin perform public.casa_pair_snapshot(g);raise exception 'FAIL: third user read private snapshot';exception when raise_exception then if sqlerrm like 'FAIL:%'then raise;end if;end;
 begin perform public.casa_pair_save_absence(g,m1,d,null,'Unauthorized');raise exception 'FAIL: third user changed private control';exception when raise_exception then if sqlerrm like 'FAIL:%'then raise;end if;end;
 perform set_config('casa.test_control',g::text,true);perform set_config('casa.test_user2',u2::text,true);
end $test$;
set local role authenticated;
do $rls$
begin
 if exists(select 1 from public.casa_pair_controls)or exists(select 1 from public.casa_pair_tasks)or exists(select 1 from public.casa_pair_completions)or exists(select 1 from public.casa_pair_absences)then raise exception 'FAIL: RLS exposes private records to the third user';end if;
 perform set_config('request.jwt.claim.sub',current_setting('casa.test_user2'),true);
 if not exists(select 1 from public.casa_pair_tasks where control_id=current_setting('casa.test_control')::uuid)then raise exception 'FAIL: second participant cannot read private tasks';end if;
end $rls$;
reset role;
select 'PASS: variable recurrence, exactly two participants, third-user RPC and RLS isolation, independent household rotation, independent absences' as result;
rollback;
