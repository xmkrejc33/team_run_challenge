-- Supabase DB health check for team_run_challenge
-- Run this in Supabase SQL editor and inspect the result sets.

-- 1) Required tables
select
  t.table_name,
  case when t.table_name is null then 'MISSING' else 'OK' end as status
from (
  values ('teams'), ('challenges'), ('activities'), ('team_members')
) as req(table_name)
left join information_schema.tables t
  on t.table_schema = 'public'
 and t.table_name = req.table_name
order by req.table_name;

-- 2) Required columns in activities
select
  req.column_name,
  case when c.column_name is null then 'MISSING' else 'OK' end as status,
  c.data_type
from (
  values ('id'), ('team_name'), ('runner_name'), ('km'), ('created_at'), ('start_time'), ('end_time')
) as req(column_name)
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = 'activities'
 and c.column_name = req.column_name
order by req.column_name;

-- 3) Required columns in challenges
select
  req.column_name,
  case when c.column_name is null then 'MISSING' else 'OK' end as status,
  c.data_type
from (
  values ('id'), ('name'), ('start_date'), ('end_date'), ('distance'), ('team_names'), ('winner_team'), ('is_active'), ('originator_id')
) as req(column_name)
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = 'challenges'
 and c.column_name = req.column_name
order by req.column_name;

-- 3b) Required columns in teams
select
  req.column_name,
  case when c.column_name is null then 'MISSING' else 'OK' end as status,
  c.data_type
from (
  values ('id'), ('name'), ('km'), ('originator_id')
) as req(column_name)
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = 'teams'
 and c.column_name = req.column_name
order by req.column_name;

-- 4) team_members columns
select
  req.column_name,
  case when c.column_name is null then 'MISSING' else 'OK' end as status,
  c.data_type
from (
  values ('id'), ('team_id'), ('user_id'), ('runner_name'), ('created_at')
) as req(column_name)
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = 'team_members'
 and c.column_name = req.column_name
order by req.column_name;

-- 5) Unique index expected by app logic (team_id, user_id)
select
  i.indexname,
  i.indexdef,
  case when i.indexname is null then 'MISSING' else 'OK' end as status
from (
  values ('team_members_team_user_idx')
) as req(indexname)
left join pg_indexes i
  on i.schemaname = 'public'
 and i.indexname = req.indexname;

-- 6) RLS status
select
  relname as table_name,
  relrowsecurity as rls_enabled
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in ('teams', 'challenges', 'activities', 'team_members')
order by relname;

-- 7) Existing policies
select
  tablename,
  policyname,
  cmd,
  permissive,
  roles
from pg_policies
where schemaname = 'public'
  and tablename in ('teams', 'challenges', 'activities', 'team_members')
order by tablename, policyname;

-- 8) Smoke test queries (run under SQL editor role)
-- If any of these fail, copy the exact error text.
select count(*) as teams_count from public.teams;
select count(*) as challenges_count from public.challenges;
select count(*) as activities_count from public.activities;
select count(*) as team_members_count from public.team_members;

-- 9) Quick data sanity in activities
select
  count(*) as total_rows,
  count(*) filter (where start_time is null) as missing_start_time,
  count(*) filter (where end_time is null) as missing_end_time,
  count(*) filter (where km is null or km <= 0) as missing_or_zero_km
from public.activities;

-- 10) Exact live relation and column types used by the mobile API.
select
  to_regclass('public.activities') as relation_name,
  c.relkind,
  c.relrowsecurity as rls_enabled
from pg_class c
where c.oid = 'public.activities'::regclass;

select
  a.attname as column_name,
  format_type(a.atttypid, a.atttypmod) as actual_type,
  not a.attnotnull as is_nullable,
  pg_get_expr(d.adbin, d.adrelid) as default_value
from pg_attribute a
left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
where a.attrelid = 'public.activities'::regclass
  and a.attnum > 0
  and not a.attisdropped
order by a.attnum;

select
  has_table_privilege('authenticated', 'public.activities', 'select') as authenticated_can_select,
  has_table_privilege('authenticated', 'public.activities', 'insert') as authenticated_can_insert,
  has_schema_privilege('authenticated', 'public', 'usage') as authenticated_schema_usage;
