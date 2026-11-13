create index if not exists casa_completions_task_household_idx on public.casa_completions(task_id,household_id);
create index if not exists casa_households_owner_idx on public.casa_households(owner_id);
create index if not exists casa_push_deliveries_task_idx on casa_private.push_deliveries(task_id);
