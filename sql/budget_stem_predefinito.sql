-- =====================================================================
-- Brown Enterprises · strumenti
-- "Budget laboratori STEM": scenario predefinito ed eliminazione per tutti.
--
-- Chiunque abbia il link puo' ora eliminare uno scenario e scegliere quello
-- predefinito, cioe' quello che si apre per primo a chi arriva sulla pagina
-- senza un link diretto e senza una bozza nel browser.
--
-- Visto che chiunque puo' eliminare, l'eliminazione e' "morbida": lo
-- scenario sparisce dalla pagina (eliminato_at valorizzato, la policy di
-- lettura lo nasconde) ma resta nella tabella. Per recuperarlo:
--   update public.be_stem_scenari set eliminato_at = null where id = '...';
-- Al massimo 20 eliminazioni al minuto, come per i salvataggi.
-- Un solo scenario predefinito alla volta (indice unico parziale).
-- Il team (be_is_team) mantiene l'eliminazione definitiva della policy
-- be_stem_scenari_delete.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo
-- budget_stem_scenari.sql.
-- =====================================================================

begin;

alter table public.be_stem_scenari
  add column if not exists predefinito boolean not null default false;
alter table public.be_stem_scenari
  add column if not exists eliminato_at timestamptz;

create unique index if not exists be_stem_scenari_un_predefinito
  on public.be_stem_scenari (predefinito) where predefinito;

-- In lettura solo gli scenari non eliminati
drop policy if exists be_stem_scenari_select on public.be_stem_scenari;
create policy be_stem_scenari_select on public.be_stem_scenari
  for select to anon, authenticated
  using (eliminato_at is null);

create or replace function public.be_stem_elimina(p_id uuid)
returns boolean
language plpgsql
security definer
volatile
set search_path = public
as $$
begin
  if (select count(*) from public.be_stem_scenari
       where eliminato_at > now() - interval '1 minute') >= 20 then
    raise exception 'Troppe eliminazioni in questo momento: riprova tra un minuto.';
  end if;
  update public.be_stem_scenari
     set eliminato_at = now(), predefinito = false
   where id = p_id and eliminato_at is null;
  return found;
end;
$$;

-- p_id null toglie il predefinito
create or replace function public.be_stem_predefinito(p_id uuid)
returns boolean
language plpgsql
security definer
volatile
set search_path = public
as $$
begin
  update public.be_stem_scenari set predefinito = false where predefinito;
  if p_id is null then
    return true;
  end if;
  update public.be_stem_scenari
     set predefinito = true
   where id = p_id and eliminato_at is null;
  return found;
end;
$$;

revoke all on function public.be_stem_elimina(uuid) from public;
revoke all on function public.be_stem_predefinito(uuid) from public;
grant execute on function public.be_stem_elimina(uuid) to anon, authenticated;
grant execute on function public.be_stem_predefinito(uuid) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
