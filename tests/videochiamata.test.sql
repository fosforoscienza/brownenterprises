-- =====================================================================
-- Test di sql/videochiamata.sql sul database vero, senza lasciare tracce:
-- tutto avviene in una transazione che alla fine viene annullata.
--
--   ssh mac-mini 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < tests/videochiamata.test.sql
--
-- Ogni controllo che fallisce interrompe lo script con un errore.
-- Servono gli account alessandro@ e luca@brown.internal.
-- =====================================================================

begin;

-- aiutanti, in uno schema che sparisce con il rollback
create schema __t;
grant usage on schema __t to anon, authenticated, service_role;

select set_config('t.u1', (select id::text from auth.users where email = 'alessandro@brown.internal'), true),
       set_config('t.u2', (select id::text from auth.users where email = 'luca@brown.internal'), true);

create function __t.uid(n int) returns uuid language sql stable as $$
  select current_setting('t.u' || n)::uuid
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
grant execute on all functions in schema __t to anon, authenticated, service_role;

select __t.check(__t.uid(1) is not null and __t.uid(2) is not null, 'ci sono gli account di Alessandro e Luca');

insert into public.be_notify_prefs (user_id, email, cal_assign)
values (__t.uid(2), 'luca@example.it', true)
on conflict (user_id) do update set email = excluded.email, cal_assign = excluded.cal_assign;

-- ---------------------------------------------------------------------
-- 1) Solo i link di call.fosforoscienza.it

select __t.as_user(1);

insert into public.be_cal_events (id, date, half, title, persons, video_url)
values ('__t_v1', current_date + 3, 'am', 'Riunione', array['Alessandro','Luca'],
        'https://call.fosforoscienza.it/call/riunione-ab12cd34ef');
select __t.check((select video_url from public.be_cal_events where id = '__t_v1')
                 = 'https://call.fosforoscienza.it/call/riunione-ab12cd34ef', 'il link della videochiamata si salva');

insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_v2', current_date + 3, 'am', 'Senza link', array['Alessandro']);
select __t.check((select video_url is null from public.be_cal_events where id = '__t_v2'), 'senza link: null');

select __t.must_fail($$update public.be_cal_events set video_url = 'https://example.com/call/x' where id = '__t_v2'$$,
                     '23514', 'un link di un altro sito viene rifiutato');
select __t.must_fail($$update public.be_cal_events set video_url = 'http://call.fosforoscienza.it/call/x' where id = '__t_v2'$$,
                     '23514', 'un link senza https viene rifiutato');
select __t.must_fail($$update public.be_cal_events set video_url = 'https://call.fosforoscienza.it/call/x"><script>' where id = '__t_v2'$$,
                     '23514', 'un link con caratteri strani viene rifiutato');

-- ---------------------------------------------------------------------
-- 2) Il link arriva alla mail di "Chi fa cosa"

reset role;
set local role service_role;
create temp table c1 on commit drop as select * from public.be_cal_notify_claim();
reset role;

select __t.check((select e->>'video_url' from c1 c, jsonb_array_elements(c.events) e
                   where c.user_id = __t.uid(2) and e->>'id' = '__t_v1')
                 = 'https://call.fosforoscienza.it/call/riunione-ab12cd34ef', 'il link arriva alla funzione della mail');

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
