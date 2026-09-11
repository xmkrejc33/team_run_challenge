-- Remove team_members after the app has migrated to public.profiles.
-- Run in Supabase SQL Editor as project owner.

begin;

drop table if exists public.team_members;

notify pgrst, 'reload schema';

commit;