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

comment on column public.be_cards.due_date is
  'Scadenza della card, mostrata nelle liste diverse da Done.';
comment on column public.be_cards.done_at is
  'Data di completamento: valorizzata quando la card entra nella lista Done, modificabile a mano.';

-- Le card gia' presenti nella lista Done ereditano la data di oggi,
-- cosi' la colonna non parte vuota.
update public.be_cards c
   set done_at = current_date
  from public.be_columns k
 where k.id = c.column_id
   and c.done_at is null
   and lower(btrim(k.name)) in ('done','fatto','fatti','completato','completati','completed','finito','finiti');
