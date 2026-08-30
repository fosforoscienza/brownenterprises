-- =====================================================================
-- Brown Enterprises · area riservata
-- Date delle schede: "due_date" (scadenza, mostrata nelle liste di lavoro)
-- e "done_at" (data di completamento, mostrata nella lista Done).
-- Nessun vincolo di esclusione fra le due: spostando una scheda in Done la
-- UI valorizza done_at e lascia la scadenza dov'era, per poterla ripristinare
-- se la scheda torna indietro.
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

alter table public.be_cards
  add column if not exists due_date date;

alter table public.be_cards
  add column if not exists done_at date;

-- Le viste per scadenza leggono le schede con data in ordine, progetto per progetto.
create index if not exists be_cards_due_date_idx
  on public.be_cards (project_id, due_date)
  where due_date is not null;
