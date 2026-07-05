begin;

alter table public.teams
  add column if not exists originator_id uuid references auth.users(id) on delete set null;

alter table public.challenges
  add column if not exists originator_id uuid references auth.users(id) on delete set null;

create index if not exists teams_originator_id_idx
  on public.teams(originator_id);

create index if not exists challenges_originator_id_idx
  on public.challenges(originator_id);

grant select, insert, update, delete on public.teams to authenticated;
grant select, insert, update, delete on public.challenges to authenticated;

commit;
