drop function public.casa_complete_task(uuid,date);
create or replace function public.casa_complete_task(p_task_id uuid,p_date date,p_expected_member uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
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
 if p_expected_member is null or p_expected_member is distinct from assigned then raise exception 'O rodízio mudou. Atualize a lista antes de concluir para registrar o favor corretamente.';end if;
 if assigned is null then raise exception 'Não há morador disponível nesta data.'; end if;
 insert into public.casa_completions(household_id,task_id,task_title,occurrence_date,original_member_id,completed_by,exempt)
 values(h,t.id,t.title,p_date,assigned,m,false);
 return public.casa_snapshot();
exception when unique_violation then raise exception 'Alguém já concluiu esta tarefa. Atualize a lista.';
end $$;

revoke all on function public.casa_complete_task(uuid,date,uuid) from public,anon;
grant execute on function public.casa_complete_task(uuid,date,uuid) to authenticated;
