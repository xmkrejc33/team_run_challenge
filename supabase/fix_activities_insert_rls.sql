-- Fix inserts into public.activities (unblock mode)
-- Run in Supabase SQL editor as project owner.

begin;

-- Temporary unblock: disable RLS on activities.
alter table public.activities disable row level security;

-- Remove all existing policies on public.activities (regardless of their names).
do $$
declare
	p record;
begin
	for p in
		select policyname
		from pg_policies
		where schemaname = 'public'
			and tablename = 'activities'
	loop
		execute format('drop policy if exists %I on public.activities', p.policyname);
	end loop;
end $$;

-- Policies are not needed while RLS is disabled.

-- Ensure table privileges are present.
grant select, insert, update, delete on public.activities to authenticated;
grant select, insert, update, delete on public.activities to anon;

commit;

-- Optional verification (run after policy changes):
-- select policyname, cmd, roles from pg_policies where schemaname='public' and tablename='activities' order by policyname;
--
-- If you want to return to strict RLS later, re-enable it and create explicit policies:
-- alter table public.activities enable row level security;
