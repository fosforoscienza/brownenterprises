-- =====================================================================
-- Brown Enterprises · area riservata
-- Abstract del progetto: un testo breve (di cosa parla, per chi e', a
-- che punto e') che si apre con l'interruttore accanto al nome.
--
-- Lo legge e lo scrive chiunque veda il progetto: il team per i
-- progetti del team, il proprietario e chi l'ha avuto condiviso per
-- quelli in «Personale». Chi ha solo la condivisione non puo' fare
-- update su be_projects, per questo si scrive con la funzione
-- be_set_project_abstract, che controlla l'accesso e tocca solo questa
-- colonna. L'interruttore acceso o spento e' una preferenza del
-- browser, non sta nel database.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo
-- categorie.sql (usa be_is_project_member).
-- =====================================================================

begin;

alter table public.be_projects
  add column if not exists abstract text not null default '';

alter table public.be_projects
  drop constraint if exists be_projects_abstract_check;

alter table public.be_projects
  add constraint be_projects_abstract_check
  check (char_length(abstract) <= 2000);

create or replace function public.be_set_project_abstract(p_project uuid, p_abstract text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.be_is_project_member(p_project) then
    raise exception 'Progetto non trovato o non accessibile'
      using errcode = '42501';
  end if;
  update public.be_projects
     set abstract = coalesce(btrim(p_abstract), '')
   where id = p_project;
end;
$$;

revoke all on function public.be_set_project_abstract(uuid, text) from public;
grant execute on function public.be_set_project_abstract(uuid, text) to authenticated;

commit;
