-- Database support for the Apple Health Shortcut import Edge Function.
-- Run in Supabase SQL Editor as project owner before deploying the function.

begin;

create table if not exists public.health_shortcut_tokens (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint health_shortcut_tokens_hash_length check (char_length(token_hash) = 64)
);

create table if not exists public.health_shortcut_imports (
  user_id uuid not null references auth.users(id) on delete cascade,
  external_id text not null,
  activity_id bigint references public.activities(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, external_id),
  constraint health_shortcut_imports_external_id_length check (
    char_length(external_id) between 8 and 200
  )
);

alter table public.health_shortcut_tokens enable row level security;
alter table public.health_shortcut_imports enable row level security;

revoke all on public.health_shortcut_tokens from anon, authenticated;
revoke all on public.health_shortcut_imports from anon, authenticated;

notify pgrst, 'reload schema';

commit;