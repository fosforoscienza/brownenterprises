-- =====================================================================
-- Brown Enterprises · area riservata
-- Area di lavoro del progetto: "in_progettazione", "in_corso" oppure
-- "amministrazione" (le tre dashboard accanto a "Project Manager").
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

alter table public.be_projects
  add column if not exists area text not null default 'in_corso';

alter table public.be_projects
  drop constraint if exists be_projects_area_check;

alter table public.be_projects
  add constraint be_projects_area_check
  check (area in ('in_progettazione','in_corso','amministrazione'));
