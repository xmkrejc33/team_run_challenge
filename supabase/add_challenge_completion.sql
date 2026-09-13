-- Store the moment and team that complete a challenge.
-- Run in Supabase SQL Editor as project owner.

begin;

alter table public.challenges
  add column if not exists end_date timestamptz;

alter table public.challenges
  add column if not exists winner_team text;

grant update (is_active, end_date, winner_team) on public.challenges to authenticated;

create or replace function public.complete_challenge_after_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  challenge_row record;
  activity_total double precision;
begin
  for challenge_row in
    select id, distance, start_date, team_names
    from public.challenges
    where is_active = true
      and exists (
        select 1
        from regexp_split_to_table(team_names, '\\s*,\\s*') as challenge_team
        where lower(trim(challenge_team)) = lower(trim(new.team_name))
      )
  loop
    select coalesce(sum(a.km), 0)
      into activity_total
    from public.activities as a
    where lower(trim(a.team_name)) = lower(trim(new.team_name))
      and coalesce(a.start_time, a.created_at) >= challenge_row.start_date;

    if activity_total >= challenge_row.distance then
      update public.challenges
      set is_active = false,
          end_date = coalesce(new.end_time, new.start_time, new.created_at, now()),
          winner_team = trim(new.team_name)
      where id = challenge_row.id
        and is_active = true;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists complete_challenge_after_activity on public.activities;
create trigger complete_challenge_after_activity
after insert on public.activities
for each row execute function public.complete_challenge_after_activity();

commit;