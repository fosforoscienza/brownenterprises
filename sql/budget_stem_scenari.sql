-- =====================================================================
-- Brown Enterprises · strumenti
-- "Budget laboratori STEM": gli scenari salvati dal simulatore
-- strumenti/budget-laboratori-stem.html.
--
-- La pagina e' pubblica (senza login): chiunque abbia il link puo' leggere
-- gli scenari e salvarne di nuovi. Per limitare i danni di una chiave anon
-- che e' pubblica per costruzione:
--   - nessun insert diretto sulla tabella: si salva solo con
--     be_stem_salva(), che controlla nome, dimensione e frequenza;
--   - nessun update: uno scenario salvato non si sovrascrive, ogni
--     salvataggio e' una riga nuova;
--   - eliminare puo' solo il team (@brown.internal, be_is_team in
--     sql/categorie.sql), per fare pulizia.
-- Limiti: nome 1-80 caratteri, autore fino a 60, dati fino a ~50 KB,
-- al massimo 20 salvataggi al minuto e 2000 scenari in tutto.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo categorie.sql.
-- =====================================================================

begin;

create table if not exists public.be_stem_scenari (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  autore      text,
  dati        jsonb not null,
  totale      numeric,
  created_at  timestamptz not null default now(),
  constraint be_stem_scenari_nome_check
    check (char_length(btrim(nome)) between 1 and 80),
  constraint be_stem_scenari_autore_check
    check (autore is null or char_length(autore) <= 60),
  constraint be_stem_scenari_dati_check
    check (jsonb_typeof(dati) = 'object' and pg_column_size(dati) <= 50000)
);

create index if not exists be_stem_scenari_created_idx
  on public.be_stem_scenari (created_at desc);

comment on table public.be_stem_scenari is
  'Scenari salvati dal simulatore pubblico strumenti/budget-laboratori-stem.html.';

alter table public.be_stem_scenari enable row level security;

revoke all on table public.be_stem_scenari from anon, authenticated;
grant select on table public.be_stem_scenari to anon, authenticated;
grant delete on table public.be_stem_scenari to authenticated;

drop policy if exists be_stem_scenari_select on public.be_stem_scenari;
create policy be_stem_scenari_select on public.be_stem_scenari
  for select to anon, authenticated
  using (true);

drop policy if exists be_stem_scenari_delete on public.be_stem_scenari;
create policy be_stem_scenari_delete on public.be_stem_scenari
  for delete to authenticated
  using (public.be_is_team(auth.uid()));

-- Salvataggio: l'unica strada per scrivere, aperta anche ad anon
create or replace function public.be_stem_salva(
  p_nome text, p_autore text, p_dati jsonb, p_totale numeric)
returns uuid
language plpgsql
security definer
volatile
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_nome is null or char_length(btrim(p_nome)) = 0 then
    raise exception 'Dai un nome allo scenario.';
  end if;
  if (select count(*) from public.be_stem_scenari
       where created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Troppi salvataggi in questo momento: riprova tra un minuto.';
  end if;
  if (select count(*) from public.be_stem_scenari) >= 2000 then
    raise exception 'L''archivio degli scenari e'' pieno: chiedi al team di fare pulizia.';
  end if;

  insert into public.be_stem_scenari (nome, autore, dati, totale)
  values (btrim(p_nome), nullif(btrim(coalesce(p_autore, '')), ''), p_dati, p_totale)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.be_stem_salva(text, text, jsonb, numeric) from public;
grant execute on function public.be_stem_salva(text, text, jsonb, numeric) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
