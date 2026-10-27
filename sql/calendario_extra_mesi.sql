-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": le colonne degli Extra si accendono mese per mese.
--
-- be_cal_people.months cambia significato. Prima era "Chi c'e'": una
-- scelta valeva anche per i mesi dopo, finche' non la si cambiava. Ora
-- { "2026-11": true } vuol dire che a novembre la colonna di quell'Extra
-- si vede nell'Agenda, per tutti, e solo a novembre. Di base gli Extra sono
-- spenti: si vedono solo dove qualcuno li accende o dove hanno qualcosa
-- segnato (questo lo calcola l'app dagli impegni).
--
-- Qui si spengono le scelte fatte col significato vecchio, cosi' di base
-- si vedono solo i sei soci.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo
-- calendario_extra_nomi.sql.
-- =====================================================================

begin;

update public.be_cal_people
   set months = '{}'::jsonb
 where months <> '{}'::jsonb;

commit;
