-- =====================================================================
-- Test di sql/calendario.sql sul database vero, senza lasciare tracce:
-- tutto avviene in una transazione che alla fine viene annullata.
--
--   ssh mac-mini 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < tests/calendario.test.sql
--
-- Ogni controllo che fallisce interrompe lo script con un errore.
-- Servono almeno due utenti in auth.users.
-- =====================================================================

begin;

-- aiutanti, in uno schema che sparisce con il rollback
create schema __t;
grant usage on schema __t to anon, authenticated;

select set_config('t.u1', (select id::text from auth.users order by created_at limit 1), true),
       set_config('t.u2', (select id::text from auth.users order by created_at offset 1 limit 1), true);

create function __t.uid(n int) returns uuid language sql stable as $$
  select (case n when 1 then current_setting('t.u1') else current_setting('t.u2') end)::uuid
$$;

/* Fa le veci di un utente collegato, come farebbe PostgREST col suo JWT */
create function __t.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', __t.uid(n), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', __t.uid(n)::text, true);
  execute 'set local role authenticated';
end $$;

create function __t.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FALLITO: %', what; end if;
  raise notice 'ok  %', what;
end $$;

/* L'istruzione deve fallire con l'errore atteso (codice SQLSTATE) */
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

select __t.check(__t.uid(1) is not null and __t.uid(2) is not null and __t.uid(1) <> __t.uid(2), 'ci sono due utenti per i test');

-- ---------------------------------------------------------------------
-- 1) impegni: un utente collegato scrive, tutti leggono

select __t.as_user(1);

insert into public.be_cal_events (id, date, half, start_time, end_time, title, persons, kind, status, project_name)
values ('__t_1', '2026-10-27', 'pm', '15:30', '16:30', 'Test lab', array['Alessandro','Luca','Marco Rossi'], 'lavoro', 'da_confermare', 'Galilei');

select __t.check((select created_by from public.be_cal_events where id = '__t_1') = __t.uid(1), 'created_by = utente collegato');
select __t.check((select persons from public.be_cal_events where id = '__t_1') = array['Alessandro','Luca','Marco Rossi'], 'persone salvate come array');
select __t.check((select source from public.be_cal_events where id = '__t_1') = 'mario', 'source di default = mario');

-- upsert come fa supabase-js con ignoreDuplicates: on conflict do nothing
insert into public.be_cal_events (id, date, title) values ('__t_1', '2026-10-28', 'Altro') on conflict (id) do nothing;
select __t.check((select title from public.be_cal_events where id = '__t_1') = 'Test lab', 'upsert ignoreDuplicates non sovrascrive');

-- upsert normale: on conflict do update
insert into public.be_cal_events (id, date, title, half) values ('__t_1', '2026-10-27', 'Test lab 2', 'am')
  on conflict (id) do update set title = excluded.title, half = excluded.half;
select __t.check((select title || half from public.be_cal_events where id = '__t_1') = 'Test lab 2am', 'upsert aggiorna');

update public.be_cal_events set updated_at = '2000-01-01' where id = '__t_1';
select __t.check((select updated_at from public.be_cal_events where id = '__t_1') > '2001-01-01', 'il trigger aggiorna updated_at');

insert into public.be_cal_events (id, date, date_end, half, title, persons, kind)
values ('__t_ferie', '2026-12-24', '2027-01-06', 'day', 'Ferie', array['Valeria'], 'ferie');
insert into public.be_cal_events (id, date, title, persons, series_id, recur)
values ('__t_s1', '2026-11-03', 'Corso', array['Lorenzo'], '__s', '{"days":[2,4],"from":"2026-11-03","to":"2026-12-17"}'),
       ('__t_s2', '2026-11-05', 'Corso', array['Lorenzo'], '__s', '{"days":[2,4],"from":"2026-11-03","to":"2026-12-17"}');
select __t.check((select count(*) from public.be_cal_events where series_id = '__s') = 2, 'serie ricorrente salvata');
select __t.check((select recur->'days' from public.be_cal_events where id = '__t_s1') = '[2,4]'::jsonb, 'regola della ricorrenza in jsonb');

-- l'altro utente vede, modifica e cancella gli impegni del team
select __t.as_user(2);
select __t.check((select count(*) from public.be_cal_events where id like '\_\_t\_%') = 4, 'un altro utente vede tutto');
update public.be_cal_events set status = 'confermato' where id = '__t_1';
select __t.check((select status from public.be_cal_events where id = '__t_1') = 'confermato', 'un altro utente modifica');
delete from public.be_cal_events where id in ('__t_s1', '__t_s2');
select __t.check((select count(*) from public.be_cal_events where series_id = '__s') = 0, 'un altro utente cancella (delete ... in)');
select __t.check((select count(*) from public.be_cal_events where 'Luca' = any(persons) and id like '\_\_t\_%') = 1, 'filtro per persona');

-- ---------------------------------------------------------------------
-- 2) vincoli

select __t.must_fail($$insert into public.be_cal_events (id, date, title, half) values ('__t_x', '2026-10-27', 'x', 'sera')$$, '23514', 'mezza giornata non valida rifiutata');
select __t.must_fail($$insert into public.be_cal_events (id, date, title, kind) values ('__t_x', '2026-10-27', 'x', 'vacanza')$$, '23514', 'tipo non valido rifiutato');
select __t.must_fail($$insert into public.be_cal_events (id, date, title, status) values ('__t_x', '2026-10-27', 'x', 'forse')$$, '23514', 'stato non valido rifiutato');
select __t.must_fail($$insert into public.be_cal_events (id, date, title, source) values ('__t_x', '2026-10-27', 'x', 'google')$$, '23514', 'origine non valida rifiutata');
select __t.must_fail($$insert into public.be_cal_events (id, date, date_end, title) values ('__t_x', '2026-10-27', '2026-10-26', 'x')$$, '23514', 'fine prima dell''inizio rifiutata');
select __t.must_fail($$insert into public.be_cal_events (id, date, title) values ('__t_x', '2026-10-27', '   ')$$, '23514', 'titolo vuoto rifiutato');
select __t.must_fail($$insert into public.be_cal_events (id, title) values ('__t_x', 'x')$$, '23502', 'data obbligatoria');
select __t.must_fail($$insert into public.be_cal_events (id, date, title) values ('__t_1', '2026-10-27', 'doppio')$$, '23505', 'id duplicato rifiutato');

-- ---------------------------------------------------------------------
-- 3) progetto cancellato: l'impegno resta, senza progetto ma col nome

select __t.as_user(1);
insert into public.be_projects (id, name, owner_id) values ('00000000-0000-4000-8000-00000000abcd', '__Progetto test', __t.uid(1));
insert into public.be_cal_events (id, date, title, project_id, project_name)
values ('__t_p', '2026-10-27', 'Con progetto', '00000000-0000-4000-8000-00000000abcd', '__Progetto test');
delete from public.be_projects where id = '00000000-0000-4000-8000-00000000abcd';
select __t.check((select project_id is null and project_name = '__Progetto test' from public.be_cal_events where id = '__t_p'),
  'progetto cancellato: project_id vuoto, nome conservato');

-- ---------------------------------------------------------------------
-- 4) link Apple: ognuno vede e cambia solo il proprio

insert into public.be_cal_feeds (user_id, person, token) values (__t.uid(1), 'Alessandro', repeat('t', 48))
  on conflict (user_id) do update set token = excluded.token;    -- se l'utente ha gia' un link vero, nel test lo si sostituisce
select __t.check((select count(*) from public.be_cal_feeds) = 1, 'il proprio link si crea e si vede');

insert into public.be_cal_feeds (user_id, person, token) values (__t.uid(1), 'Alessandro', repeat('u', 48))
  on conflict (user_id) do update set token = excluded.token, person = excluded.person;
select __t.check((select token from public.be_cal_feeds) = repeat('u', 48), 'rigenerare il link sostituisce il token');

select __t.must_fail($$insert into public.be_cal_feeds (user_id, person, token) values (__t.uid(2), 'Luca', repeat('v', 48))$$,
  '42501', 'non si crea il link per un altro utente');
select __t.must_fail($$update public.be_cal_feeds set token = 'corto'$$, '23514', 'token corto rifiutato');

select __t.as_user(2);
select __t.check((select count(*) from public.be_cal_feeds where user_id = __t.uid(1)) = 0, 'un altro utente non vede il link');
update public.be_cal_feeds set token = repeat('h', 48) where user_id = __t.uid(1);
delete from public.be_cal_feeds where user_id = __t.uid(1);
reset role;
select __t.check((select token from public.be_cal_feeds where user_id = __t.uid(1)) = repeat('u', 48),
  'un altro utente non modifica ne'' cancella il link');

-- ---------------------------------------------------------------------
-- 5) il feed letto da Apple (ruolo anon, solo token)

insert into public.be_cal_events (id, date, title, persons, source) values
  ('__t_f1', current_date + 1,   'Nel feed',   array['Alessandro','Luca'], 'mario'),
  ('__t_f2', current_date + 1,   'Da Apple',   array['Alessandro'],        'apple'),
  ('__t_f3', current_date - 365, 'Vecchio',    array['Alessandro'],        'mario'),
  ('__t_f4', current_date + 1,   'Di Valeria', array['Valeria'],           'mario');

set local role anon;
select __t.check((select count(*) from public.be_cal_events) = 0, 'anon non legge gli impegni');
select __t.check((select count(*) from public.be_cal_feeds) = 0, 'anon non legge i link');
select __t.must_fail($$insert into public.be_cal_events (id, date, title) values ('__t_anon', '2026-10-27', 'x')$$, '42501', 'anon non scrive');

select __t.check((select count(*) from public.be_cal_feed(repeat('u', 48)) where id = '__t_f1') = 1, 'feed: impegno della persona presente');
select __t.check((select count(*) from public.be_cal_feed(repeat('u', 48)) where id = '__t_f2') = 0, 'feed: impegni arrivati da Apple esclusi');
select __t.check((select count(*) from public.be_cal_feed(repeat('u', 48)) where id = '__t_f3') = 0, 'feed: impegni di un anno fa esclusi');
select __t.check((select count(*) from public.be_cal_feed(repeat('u', 48)) where id = '__t_f4') = 0, 'feed: impegni di altri esclusi');
select __t.check((select count(*) from public.be_cal_feed(repeat('t', 48))) = 0, 'feed: il token vecchio non funziona piu''');
select __t.check((select count(*) from public.be_cal_feed('corto')) = 0, 'feed: token corto, niente');
select __t.check((select count(*) from public.be_cal_feed(null)) = 0, 'feed: token nullo, niente');
select __t.check((select count(*) from public.be_cal_feed(''' or 1=1 --' || repeat('x', 40))) = 0, 'feed: nessuna iniezione SQL');

reset role;

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
