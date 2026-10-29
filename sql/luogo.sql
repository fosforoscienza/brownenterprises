-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": il luogo di un impegno.
--
-- location e' il testo che si vede (nome e indirizzo); location_lat e
-- location_lon le coordinate, quando il luogo e' stato scelto tra i
-- suggerimenti di OpenStreetMap. Cliccando il luogo si apre Google Maps;
-- il feed per Apple Calendar (be_cal_feed, che restituisce tutte le
-- colonne) lo passa come LOCATION.
--
-- Le policy di be_cal_events valgono anche per le colonne nuove.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo calendario.sql.
-- =====================================================================

alter table public.be_cal_events
  add column if not exists location text;

alter table public.be_cal_events
  add column if not exists location_lat double precision;

alter table public.be_cal_events
  add column if not exists location_lon double precision;

alter table public.be_cal_events
  drop constraint if exists be_cal_events_location_check;
alter table public.be_cal_events
  add constraint be_cal_events_location_check check (
    (location is null or length(location) <= 300) and
    (location_lat is null or location_lat between -90 and 90) and
    (location_lon is null or location_lon between -180 and 180)
  );

comment on column public.be_cal_events.location is
  'Luogo dell''impegno (nome e indirizzo), facoltativo.';
comment on column public.be_cal_events.location_lat is
  'Latitudine del luogo, se scelto tra i suggerimenti di OpenStreetMap.';
comment on column public.be_cal_events.location_lon is
  'Longitudine del luogo, se scelto tra i suggerimenti di OpenStreetMap.';
