begin;
do $test$
declare u uuid:=gen_random_uuid();v uuid:=gen_random_uuid();h uuid;m uuid;other uuid;g uuid;t uuid;private_task uuid;payload jsonb;instructions text:=E'Retirar os resíduos.\nRepor a areia e limpar a borda. <sem HTML>';
begin
 insert into auth.users(id,email)values(u,'description-a-'||u||'@example.invalid'),(v,'description-b-'||v||'@example.invalid');
 perform set_config('request.jwt.claim.sub',u::text,true);perform public.casa_create_household('Descriptions test','A');h:=public.casa_my_household();select id into m from public.casa_members where user_id=u and household_id=h;
 select id,to_jsonb(x)into t,payload from public.casa_tasks x where household_id=h limit 1;
 if payload->>'description'<>''then raise exception 'FAIL: description not optional by default';end if;
 perform public.casa_save_task(payload||jsonb_build_object('description',instructions));
 if (select description from public.casa_tasks where id=t)is distinct from instructions then raise exception 'FAIL: shared instructions not saved';end if;
 perform public.casa_save_task(payload-'description');
 if (select description from public.casa_tasks where id=t)is distinct from instructions then raise exception 'FAIL: older client erased instructions';end if;
 perform public.casa_save_task(payload||jsonb_build_object('description',''));
 if (select description from public.casa_tasks where id=t)<>''then raise exception 'FAIL: description cannot be cleared';end if;
 perform public.casa_add_member('B');select id into other from public.casa_members where household_id=h and name='B';
 g:=(public.casa_pair_create('Instruções privadas',null)->>'id')::uuid;
 perform public.casa_pair_save_task(g,(payload-'id')||jsonb_build_object('description',instructions));
 select id into private_task from public.casa_pair_tasks where control_id=g;
 if (select description from public.casa_pair_tasks where id=private_task)is distinct from instructions then raise exception 'FAIL: private instructions not saved';end if;
 perform public.casa_pair_save_task(g,(payload||jsonb_build_object('id',private_task))-'description');
 if (select description from public.casa_pair_tasks where id=private_task)is distinct from instructions then raise exception 'FAIL: legacy private edit erased instructions';end if;
 begin perform public.casa_pair_save_task(g,payload||jsonb_build_object('id',private_task,'description',repeat('x',5001)));raise exception 'FAIL: description size limit ignored';exception when check_violation then null;end;
 update public.casa_members set user_id=v where id=other;
 perform set_config('request.jwt.claim.sub',v::text,true);
 begin perform public.casa_pair_snapshot(g);raise exception 'FAIL: private instructions visible to outsider';exception when raise_exception then if sqlerrm like 'FAIL:%'then raise;end if;end;
end $test$;
select 'PASS: optional instructions, shared/private saves, line breaks, clearing, legacy edits preserved, size limit and private isolation' as result;
rollback;
