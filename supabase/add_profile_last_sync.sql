-- Store the latest activity synchronization time for every runner.
-- Run in Supabase SQL Editor as project owner.

begin;

alter table public.profiles
  add column if not exists last_sync_at timestamptz;

create or replace function public.update_profile_last_sync_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
  set last_sync_at = now(), updated_at = now()
  where runner_name = new.runner_name
    and team_name is not distinct from new.team_name;

  return new;
end;
$$;

drop trigger if exists activities_update_profile_last_sync on public.activities;
create trigger activities_update_profile_last_sync
after insert on public.activities
for each row
execute function public.update_profile_last_sync_at();

notify pgrst, 'reload schema';

commit;