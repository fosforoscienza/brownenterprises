-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": il luogo scelto tra i suggerimenti di Google Maps.
--
-- location_place_id e' l'identificativo del posto su Google Maps: col
-- link "Apri in Google Maps" apre proprio quel posto (scheda, orari)
-- invece di cercare il testo. Le condizioni di Google permettono di
-- conservare il place_id ma non le coordinate, che restano solo per i
-- luoghi presi da OpenStreetMap (location_lat, location_lon).
--
-- Le policy di be_cal_events valgono anche per la colonna nuova.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo luogo.sql.
-- =====================================================================

alter table public.be_cal_events
  add column if not exists location_place_id text;

alter table public.be_cal_events
  drop constraint if exists be_cal_events_place_id_check;
alter table public.be_cal_events
  add constraint be_cal_events_place_id_check check (
    location_place_id is null or length(location_place_id) <= 300
  );

comment on column public.be_cal_events.location_place_id is
  'place_id di Google Maps, se il luogo e'' stato scelto tra i suoi suggerimenti.';

notify pgrst, 'reload schema';
