alter table public.casa_tasks add column description text not null default '' check(length(description)<=5000);
alter table public.casa_pair_tasks add column description text not null default '' check(length(description)<=5000);
do $$declare def text;signature text;begin
 foreach signature in array array['public.casa_save_task(jsonb)','public.casa_pair_save_task(uuid,jsonb)']loop
 select pg_get_functiondef(signature::regprocedure)into def;
 if signature='public.casa_save_task(jsonb)'then
 def:=replace(def,'duration_minutes,interval_days)','duration_minutes,interval_days,description)');
 def:=replace(def,'coalesce((p_task->>''interval_days'')::integer,1));','coalesce((p_task->>''interval_days'')::integer,1),coalesce(p_task->>''description'',''''));');
 def:=replace(def,'update public.casa_tasks set title=','update public.casa_tasks set description=case when p_task ? ''description'' then coalesce(p_task->>''description'','''') else description end,title=');
 else
 def:=replace(def,'interval_days,duration_minutes)','interval_days,duration_minutes,description)');
 def:=replace(def,'(p_task->>''duration_minutes'')::integer);','(p_task->>''duration_minutes'')::integer,coalesce(p_task->>''description'',''''));');
 def:=replace(def,'update public.casa_pair_tasks set title=','update public.casa_pair_tasks set description=case when p_task ? ''description'' then coalesce(p_task->>''description'','''') else description end,title=');
 end if;
 execute def;
 end loop;
end $$;
