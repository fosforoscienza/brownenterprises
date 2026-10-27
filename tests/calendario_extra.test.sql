-- =====================================================================
-- Test di sql/calendario_extra.sql e sql/calendario_extra_nomi.sql sul
-- database vero, senza lasciare tracce: tutto avviene in una transazione
-- che alla fine viene annullata.
--
--   ssh mac-mini 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < tests/calendario_extra.test.sql
--
-- Ogni controllo che fallisce interrompe lo script con un errore.
-- Serve almeno un utente in auth.users.
-- =====================================================================

begin;

create schema __t;
grant usage on schema __t to anon, authenticated;

select set_config('t.u1', (select id::text from auth.users order by created_at limit 1), true);

create function __t.as_user() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t.u1'), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
  execute 'set local role authenticated';
end $$;

create function __t.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FALLITO: %', what; end if;
  raise notice 'ok  %', what;
end $$;

create function __t.must_fail(stmt text, expected text, what text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlstate = expected then
      raise notice 'ok  %', what;
      return;
    end if;
    raise exception 'FALLITO: % (errore diverso: % %)', what, sqlstate, sqlerrm;
  end;
  raise exception 'FALLITO: % (nessun errore)', what;
end $$;

select __t.as_user();

insert into public.be_cal_people (name, months) values ('__Anna', '{"2099-01": true}'), ('__Bruno', '{}'), ('__Carla', '{}');
insert into public.be_cal_events (id, date, half, title, persons, kind, status, source) values
  ('00000000-0000-4000-8000-00000000e001', '2099-01-10', 'am', '__uno', array['__Anna', 'Luca'], 'lavoro', 'confermato', 'mario'),
  ('00000000-0000-4000-8000-00000000e002', '2099-01-11', 'am', '__due', array['__Anna', '__Dario'], 'lavoro', 'confermato', 'mario'),
  ('00000000-0000-4000-8000-00000000e003', '2099-03-12', 'am', '__tre', array['__Dario'], 'lavoro', 'confermato', 'mario'),
  ('00000000-0000-4000-8000-00000000e004', '2099-01-13', 'am', '__quattro', array['luca', '__carla', ' __Carla ', 'Luca'], 'lavoro', 'confermato', 'mario');

-- ---------------------------------------------------------------------
-- 0) ogni nome fuori dai soci e' un Extra (sql/calendario_extra_nomi.sql)

select __t.check((select months from public.be_cal_people where name = '__Dario') = '{"2099-01": true}'::jsonb,
  'un nome nuovo in un impegno entra tra gli Extra, dal mese dell''impegno');
select __t.check((select persons from public.be_cal_events where id = '00000000-0000-4000-8000-00000000e004') = array['Luca', '__Carla'],
  'nomi scritti bene e una volta sola (soci ed Extra)');
select __t.check(not exists (select 1 from public.be_cal_people where lower(name) = 'luca'),
  'i soci non diventano Extra');

-- ---------------------------------------------------------------------
-- 1) rinominare: elenco e impegni insieme

select __t.check(public.be_cal_rename_person('__Anna', '  __Anna   Maria ') = '__Anna Maria',
  'il nome nuovo si pulisce dagli spazi');
select __t.check(exists (select 1 from public.be_cal_people where name = '__Anna Maria')
                 and not exists (select 1 from public.be_cal_people where name = '__Anna'),
  'nell''elenco cambia il nome');
select __t.check((select persons from public.be_cal_events where id = '00000000-0000-4000-8000-00000000e001') = array['__Anna Maria', 'Luca'],
  'negli impegni cambia il nome e resta l''ordine');

select __t.must_fail($$select public.be_cal_rename_person('__Bruno', '__carla')$$, '23505',
  'non si prende il nome di un altro Extra');
select __t.must_fail($$select public.be_cal_rename_person('__Bruno', '   ')$$, '22023',
  'niente nome vuoto');
select __t.check(public.be_cal_rename_person('__Bruno', '__bruno') = '__bruno',
  'si possono cambiare solo le maiuscole');

-- due Extra in elenco: si uniscono solo se lo si chiede
select __t.must_fail($$select public.be_cal_rename_person('__Dario', '__anna maria')$$, '23505',
  'senza merge due Extra non si uniscono');
select __t.must_fail($$select public.be_cal_rename_person('__Dario', 'valeria')$$, '22023',
  'un Extra non prende il nome di un socio');
select __t.check(public.be_cal_rename_person('__Dario', '__anna maria', true) = '__Anna Maria',
  'con merge si uniscono, col nome di chi c''era gia''');
select __t.check(not exists (select 1 from public.be_cal_people where name = '__Dario'),
  'dopo l''unione resta una persona sola');
select __t.check((select months from public.be_cal_people where name = '__Anna Maria') = '{"2099-01": true}'::jsonb,
  'unendo, i mesi si sommano');
select __t.check((select persons from public.be_cal_events where id = '00000000-0000-4000-8000-00000000e002') = array['__Anna Maria'],
  'unendo due nomi nello stesso impegno, la persona resta una volta sola');
select __t.check((select persons from public.be_cal_events where id = '00000000-0000-4000-8000-00000000e003') = array['__Anna Maria'],
  'il nome cambia anche dove era da solo');

-- ---------------------------------------------------------------------
-- 2) ordine

select public.be_cal_order_people(array['__Carla', '__bruno', '__Anna Maria']);
select __t.check((select array_agg(name order by position) from public.be_cal_people
                   where name in ('__Carla', '__bruno', '__Anna Maria')) = array['__Carla', '__bruno', '__Anna Maria'],
  'l''ordine si salva');

reset role;
select __t.check(not has_function_privilege('anon', 'public.be_cal_rename_person(text, text, boolean)', 'execute'),
  'chi non e'' collegato non rinomina');

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
