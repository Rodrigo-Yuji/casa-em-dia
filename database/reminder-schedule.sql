create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create function casa_private.dispatch_reminders() returns bigint language sql security definer set search_path='' as $$
 select net.http_post(
 url:='https://acwxvgvzbrwnmjsfipqn.supabase.co/functions/v1/casa-reminders',
 headers:=jsonb_build_object('Content-Type','application/json','x-casa-cron',c.cron_token),
 body:='{}'::jsonb,timeout_milliseconds:=20000
 ) from casa_private.push_config c where singleton
$$;
revoke all on function casa_private.dispatch_reminders() from public,anon,authenticated;
select cron.schedule('casa-reminders-every-minute','* * * * *','select casa_private.dispatch_reminders()');
