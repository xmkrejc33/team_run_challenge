-- Standalone user profiles outside Supabase Auth JWT metadata.
-- Run in Supabase SQL Editor as project owner.

begin;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  runner_name text not null default 'Anonymní běžec',
  team_id bigint references public.teams(id) on delete set null,
  team_name text,
  avatar_base64 text,
  last_sync_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists last_sync_at timestamptz;

-- Copy existing profile metadata before it is removed from auth.users.
insert into public.profiles (user_id, runner_name, team_id, team_name, avatar_base64)
select
  u.id,
  coalesce(nullif(trim(u.raw_user_meta_data->>'runner_name'), ''), 'Anonymní běžec'),
  case
    when u.raw_user_meta_data->>'team_id' ~ '^[0-9]+$'
      then (u.raw_user_meta_data->>'team_id')::bigint
    else null
  end,
  nullif(trim(u.raw_user_meta_data->>'team_name'), ''),
  nullif(u.raw_user_meta_data->>'avatar_base64', '')
from auth.users u
on conflict (user_id) do update set
  runner_name = excluded.runner_name,
  team_id = excluded.team_id,
  team_name = excluded.team_name,
  avatar_base64 = coalesce(excluded.avatar_base64, public.profiles.avatar_base64),
  updated_at = now();

alter table public.profiles enable row level security;

drop policy if exists "profiles read own" on public.profiles;
drop policy if exists "profiles read same team" on public.profiles;
drop policy if exists "profiles read all authenticated" on public.profiles;
create policy "profiles read all authenticated"
on public.profiles
for select
to authenticated
using (true);

drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles insert own"
on public.profiles
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own"
on public.profiles
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

grant select, insert, update on public.profiles to authenticated;
notify pgrst, 'reload schema';

commit;

-- After verifying profiles, remove the old large JWT metadata:
-- update auth.users
-- set raw_user_meta_data = raw_user_meta_data - 'avatar_base64'
-- where raw_user_meta_data ? 'avatar_base64';
