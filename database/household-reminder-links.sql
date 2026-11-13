do $$declare def text;original text;begin
 select pg_get_functiondef('public.casa_push_due()'::regprocedure)into original;
 def:=replace(original,'d.day as occurrence_date,null::uuid as control_id','d.day as occurrence_date,null::uuid as control_id,d.id as household_id');
 def:=replace(def,'t.title,t.emoji,d.day,g.id','t.title,t.emoji,d.day,g.id,d.id');
 if def=original then raise exception 'Unexpected reminder function definition';end if;
 execute def;
end $$;
