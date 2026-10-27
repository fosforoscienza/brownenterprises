-- =====================================================================
-- Test di sql/calendario_extra.sql sul database vero, senza lasciare
-- tracce: tutto avviene in una transazione che alla fine viene annullata.
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

insert into public.be_cal_people (name, months) values ('__Anna', '{}'), ('__Bruno', '{}'), ('__Carla', '{}');
insert into public.be_cal_events (id, date, half, title, persons, kind, status, source) values
  ('00000000-0000-4000-8000-00000000e001', '2099-01-10', 'am', '__uno', array['__Anna', 'Luca'], 'lavoro', 'confermato', 'mario'),
  ('00000000-0000-4000-8000-00000000e002', '2099-01-11', 'am', '__due', array['__Anna', '__Dario'], 'lavoro', 'confermato', 'mario'),
  ('00000000-0000-4000-8000-00000000e003', '2099-01-12', 'am', '__tre', array['__Dario'], 'lavoro', 'confermato', 'mario');

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

-- un nome scritto solo negli impegni: due persone diventano una
select public.be_cal_rename_person('__Dario', '__Anna Maria');
select __t.check((select persons from public.be_cal_events where id = '00000000-0000-4000-8000-00000000e002') = array['__Anna Maria'],
  'unendo due nomi nello stesso impegno, la persona resta una volta sola');
select __t.check((select persons from public.be_cal_events where id = '00000000-0000-4000-8000-00000000e003') = array['__Anna Maria'],
  'il nome scritto a mano cambia anche dove era da solo');

-- ---------------------------------------------------------------------
-- 2) ordine

select public.be_cal_order_people(array['__Carla', '__bruno', '__Anna Maria']);
select __t.check((select array_agg(name order by position) from public.be_cal_people
                   where name in ('__Carla', '__bruno', '__Anna Maria')) = array['__Carla', '__bruno', '__Anna Maria'],
  'l''ordine si salva');

reset role;
select __t.check(not has_function_privilege('anon', 'public.be_cal_rename_person(text, text)', 'execute'),
  'chi non e'' collegato non rinomina');

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
