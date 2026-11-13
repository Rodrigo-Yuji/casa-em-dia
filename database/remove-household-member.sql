create function public.casa_household_remove_member(p_member uuid)returns void language plpgsql security definer set search_path=''as $$
declare h uuid:=public.casa_my_household();m public.casa_members;replacement uuid;
begin
 perform 1 from public.casa_households where id=h and owner_id=auth.uid()for update;
 if not found then raise exception 'Só o responsável pela casa pode remover moradores.';end if;
 select * into m from public.casa_members where id=p_member and household_id=h and is_active for update;
 if m.id is null then raise exception 'Morador indisponível.';end if;
 if m.user_id=auth.uid()then raise exception 'Você não pode remover o responsável da casa. Use o gerenciador de casas.';end if;
 update public.casa_members set is_active=false where id=m.id;
 -- Keep the person's devices connected to their other houses, when present.
 select id into replacement from public.casa_members where user_id=m.user_id and is_active and household_id<>h order by created_at,id limit 1;
 if replacement is not null then update public.casa_push_subscriptions set member_id=replacement where member_id=m.id;end if;
 delete from public.casa_push_subscriptions where member_id=m.id;
 update public.casa_user_preferences set current_household_id=case when current_household_id=h then null else current_household_id end,default_household_id=case when default_household_id=h then null else default_household_id end where user_id=m.user_id;
 -- A remaining active participant can continue managing a shared private control.
 update public.casa_pair_controls g set created_by=other.user_id
 from public.casa_members other where g.household_id=h and g.created_by=m.user_id and m.id in(g.member_a,g.member_b)
 and other.id=case when g.member_a=m.id then g.member_b else g.member_a end and other.is_active and other.user_id is not null;
 update public.casa_households set invite_code=gen_random_uuid()where id=h;
end $$;
revoke all on function public.casa_household_remove_member(uuid)from public,anon;
grant execute on function public.casa_household_remove_member(uuid)to authenticated;
