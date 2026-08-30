-- =====================================================================
-- Brown Enterprises · area riservata
-- Date sulle card: scadenza (To Do / In Progress) e completamento (Done)
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

alter table public.be_cards add column if not exists due_date date;
alter table public.be_cards add column if not exists done_at  date;

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
