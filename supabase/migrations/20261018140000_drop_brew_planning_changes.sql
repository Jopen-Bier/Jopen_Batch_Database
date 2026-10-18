-- Drop the unused view brew_planning_changes (agreed with Jaap, 18-10-2026).
-- No page or script reads it; the planning history popup uses
-- brew_planning_history_detailed. Definition kept in git history
-- (supabase/schema.sql) should it be needed again. No CASCADE: nothing
-- depends on it (checked 18-10).
drop view public.brew_planning_changes;
