-- Deep diagnostics for INSERT into public.teams under authenticated role.
-- Run in Supabase SQL Editor.

begin;

-- 1) Structure and constraints
select
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'teams'
order by ordinal_position;

select
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname = 'teams'
order by c.conname;

select
  tg.tgname,
  pg_get_triggerdef(tg.oid) as definition
from pg_trigger tg
join pg_class t on t.oid = tg.tgrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname = 'teams'
  and not tg.tgisinternal
order by tg.tgname;

-- 2) Policy overview for teams
select tablename, policyname, cmd, permissive, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'teams'
order by policyname;

-- 3) Simulate authenticated insert and capture exact DB error diagnostics
drop function if exists public._diag_try_insert_team(text, uuid);
create function public._diag_try_insert_team(p_test_name text, p_originator uuid default null)
returns table(
  test_name text,
  status text,
  sqlstate text,
  message text,
  detail text,
  hint text
)
language plpgsql
security invoker
as $$
declare
  v_name text := lower(p_test_name) || '_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_state text;
  v_msg text;
  v_detail text;
  v_hint text;
begin
  begin
    if p_originator is null then
      insert into public.teams(name, km)
      values (v_name, 0);
    else
      insert into public.teams(name, km, originator_id)
      values (v_name, 0, p_originator);
    end if;

    return query
    select p_test_name, 'OK', null::text, 'Inserted ' || v_name, null::text, null::text;
  exception when others then
    get stacked diagnostics
      v_state = returned_sqlstate,
      v_msg = message_text,
      v_detail = pg_exception_detail,
      v_hint = pg_exception_hint;

    return query
    select p_test_name, 'FAIL', v_state, v_msg, coalesce(v_detail, '-'), coalesce(v_hint, '-');
  end;
end;
$$;

set local role authenticated;
set local "request.jwt.claim.role" = 'authenticated';
set local "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

-- Verify auth context visible to policies/functions.
select
  current_user as current_user_role,
  current_setting('request.jwt.claim.role', true) as jwt_role,
  current_setting('request.jwt.claim.sub', true) as jwt_sub,
  auth.uid() as auth_uid;

select * from public._diag_try_insert_team('TEST_A', '11111111-1111-1111-1111-111111111111'::uuid)
union all
select * from public._diag_try_insert_team('TEST_B', null)
order by test_name;

reset role;

drop function if exists public._diag_try_insert_team(text, uuid);

rollback;
