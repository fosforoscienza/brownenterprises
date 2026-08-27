-- =====================================================================
-- Brown Enterprises · area riservata
-- Spazio del progetto: "progetti" oppure "bandi" (colonna sinistra divisa in due sezioni)
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

alter table public.be_projects
  add column if not exists space text not null default 'progetti';

alter table public.be_projects
  drop constraint if exists be_projects_space_check;

alter table public.be_projects
  add constraint be_projects_space_check check (space in ('progetti','bandi'));
