-- Minimal seed data for team_run_challenge
-- Safe to run multiple times (uses WHERE NOT EXISTS checks)

-- Teams
insert into public.teams (name, km)
select 'Vlci', 0
where not exists (
  select 1 from public.teams where lower(name) = lower('Vlci')
);

insert into public.teams (name, km)
select 'Rysi', 0
where not exists (
  select 1 from public.teams where lower(name) = lower('Rysi')
);

insert into public.teams (name, km)
select 'Jelenci', 0
where not exists (
  select 1 from public.teams where lower(name) = lower('Jelenci')
);

-- One active challenge starting today with all seeded teams
insert into public.challenges (name, start_date, distance, team_names, is_active)
select
  'Letni vyzva',
  now(),
  100.0,
  'Vlci, Rysi, Jelenci',
  true
where not exists (
  select 1 from public.challenges where lower(name) = lower('Letni vyzva')
);

-- Quick verification
select count(*) as teams_count from public.teams;
select count(*) as challenges_count from public.challenges;
select count(*) as activities_count from public.activities;
