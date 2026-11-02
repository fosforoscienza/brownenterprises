-- =====================================================================
-- Test di sql/calendario_email.sql sul database vero, senza lasciare
-- tracce: tutto avviene in una transazione che alla fine viene annullata.
--
--   ssh mac-mini 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < tests/calendario_email.test.sql
--
-- Ogni controllo che fallisce interrompe lo script con un errore.
-- Servono gli account alessandro@, luca@ e valeria@brown.internal.
-- =====================================================================

begin;

-- aiutanti, in uno schema che sparisce con il rollback
create schema __t;
grant usage on schema __t to anon, authenticated, service_role;

select set_config('t.u1', (select id::text from auth.users where email = 'alessandro@brown.internal'), true),
       set_config('t.u2', (select id::text from auth.users where email = 'luca@brown.internal'), true),
       set_config('t.u3', (select id::text from auth.users where email = 'valeria@brown.internal'), true);

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

/* Nessun utente collegato: editor SQL, script */
create function __t.as_nobody() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'reset role';
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

/* Le righe in coda per gli impegni di prova */
create function __t.queued(p_event text, n int) returns bigint language sql stable security definer as $$
  select count(*) from public.be_cal_notify where event_id = p_event and user_id = __t.uid(n)
$$;
grant execute on all functions in schema __t to anon, authenticated, service_role;

select __t.check(__t.uid(1) is not null and __t.uid(2) is not null and __t.uid(3) is not null,
                 'ci sono gli account di Alessandro, Luca e Valeria');

-- le preferenze: Luca e Alessandro ricevono, Valeria ha spento le mail
-- degli impegni, chi non ha indirizzo non riceve niente
insert into public.be_notify_prefs (user_id, email, cal_assign)
values (__t.uid(1), 'ale@example.it', true), (__t.uid(2), 'luca@example.it', true), (__t.uid(3), 'vale@example.it', false)
on conflict (user_id) do update set email = excluded.email, cal_assign = excluded.cal_assign;

-- ---------------------------------------------------------------------
-- 1) La coda si riempie solo per chi riceve l'impegno da un altro

select __t.as_user(1);

insert into public.be_cal_events (id, date, half, title, persons, location, notes)
values ('__t_e1', current_date + 10, 'am', 'Montaggio', array['Alessandro','luca','Valeria','Marco Extra'], 'Fermo', 'Portare il trapano');

select __t.check(__t.queued('__t_e1', 2) = 1, 'Luca (scritto minuscolo) e'' in coda');
select __t.check(__t.queued('__t_e1', 1) = 0, 'chi crea l''impegno non riceve la mail');
select __t.check(__t.queued('__t_e1', 3) = 0, 'chi ha spento le mail degli impegni non e'' in coda');
select __t.check((select count(*) from public.be_cal_notify) = 0, 'gli utenti collegati non leggono la coda');

reset role;
select __t.check((select count(*) from public.be_cal_notify where event_id = '__t_e1') = 1, 'gli Extra non hanno account: niente coda');
select __t.check((select kind = 'created' and actor_id = __t.uid(1) from public.be_cal_notify where event_id = '__t_e1'),
                 'tipo created, autore Alessandro');

-- 2) Persone aggiunte dopo: solo loro

update public.be_notify_prefs set cal_assign = true where user_id = __t.uid(3);
select __t.as_user(1);

insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_e2', current_date + 3, 'pm', 'Riunione', array['Alessandro','Luca']);
-- upsert come quello dell'app: stesse persone, nessuna riga in piu'
insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_e2', current_date + 4, 'pm', 'Riunione spostata', array['Alessandro','Luca'])
on conflict (id) do update set date = excluded.date, title = excluded.title, persons = excluded.persons;
select __t.check(__t.queued('__t_e2', 2) = 1, 'spostare l''impegno non rimette in coda');

update public.be_cal_events set persons = array['Alessandro','Luca','Valeria'] where id = '__t_e2';
select __t.check(__t.queued('__t_e2', 3) = 1, 'chi viene aggiunto dopo entra in coda');
reset role;
select __t.check((select kind from public.be_cal_notify where event_id = '__t_e2' and user_id = __t.uid(3)) = 'added', 'tipo added');

select __t.as_user(1);
update public.be_cal_events set persons = array['Alessandro'] where id = '__t_e2';
update public.be_cal_events set persons = array['Alessandro','Luca'] where id = '__t_e2';
select __t.check(__t.queued('__t_e2', 2) = 1, 'togliere e rimettere una persona non manda una seconda mail');

-- 3) Quando non parte niente

insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_past', current_date - 2, 'am', 'Ieri', array['Luca']);
select __t.check(__t.queued('__t_past', 2) = 0, 'impegno passato: niente mail');

insert into public.be_cal_events (id, date, half, title, persons, source)
values ('__t_apple', current_date + 2, 'am', 'Da Apple', array['Luca'], 'apple');
select __t.check(__t.queued('__t_apple', 2) = 0, 'impegno importato da Apple: niente mail');

select __t.as_user(2);
insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_self', current_date + 2, 'am', 'Mio', array['Luca']);
select __t.check(__t.queued('__t_self', 2) = 0, 'un impegno per se stessi: niente mail');

select __t.as_nobody();
insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_sql', current_date + 2, 'am', 'Da script', array['Luca']);
select __t.check(__t.queued('__t_sql', 2) = 0, 'senza utente collegato (editor SQL): niente mail');

-- ---------------------------------------------------------------------
-- 4) Presa in carico e invio: solo service_role

select __t.as_user(2);
select __t.must_fail('select * from public.be_cal_notify_claim()', '42501', 'gli utenti collegati non svuotano la coda');
select __t.must_fail('select public.be_cal_notify_done(array[1::bigint], true)', '42501', 'gli utenti collegati non segnano gli invii');

-- un impegno eliminato o una persona tolta prima dell'invio: la riga sparisce
select __t.as_user(1);
insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_gone', current_date + 5, 'am', 'Annullato', array['Luca']),
       ('__t_moved', current_date + 5, 'am', 'Cambiato', array['Luca']);
delete from public.be_cal_events where id = '__t_gone';
update public.be_cal_events set persons = array['Valeria'] where id = '__t_moved';

reset role;
set local role service_role;
create temp table c1 on commit drop as select * from public.be_cal_notify_claim();
reset role;

select __t.check(__t.queued('__t_gone', 2) = 0, 'impegno eliminato prima dell''invio: tolto dalla coda');
select __t.check(__t.queued('__t_moved', 2) = 0, 'persona tolta prima dell''invio: tolta dalla coda');
select __t.check(__t.queued('__t_moved', 3) = 1, '... e chi l''ha sostituita e'' in coda');

select __t.check((select email from c1 where user_id = __t.uid(2)) = 'luca@example.it', 'Luca: indirizzo di be_notify_prefs');
select __t.check((select count(*) from c1 c, jsonb_array_elements(c.events) e
                   where c.user_id = __t.uid(2) and e->>'id' like '__t_%') = 2, 'Luca: una mail con i suoi due impegni');
select __t.check((select e->>'title' || '|' || (e->>'location') || '|' || (e->>'notes') || '|' || (e->>'actor') || '|' || (e->>'change')
                    from c1 c, jsonb_array_elements(c.events) e
                   where c.user_id = __t.uid(2) and e->>'id' = '__t_e1')
                 = 'Montaggio|Fermo|Portare il trapano|' || (select display_name from public.be_profiles where id = __t.uid(1)) || '|created',
                 'i dettagli dell''impegno arrivano alla funzione');
select __t.check((select count(*) from public.be_cal_notify where event_id like '__t_%' and sent_at is null and claimed_at is null) = 0,
                 'tutte le righe in coda sono prese in carico');

set local role service_role;
select __t.check((select count(*) from public.be_cal_notify_claim() c, jsonb_array_elements(c.events) e
                   where e->>'id' like '__t_%') = 0, 'una seconda chiamata non riprende le stesse righe');

-- Resend non risponde: le righe tornano in coda
select public.be_cal_notify_done((select ids from c1 where user_id = __t.uid(2)), false);
create temp table c2 on commit drop as select * from public.be_cal_notify_claim();
select __t.check((select ids from c2 where user_id = __t.uid(2)) = (select ids from c1 where user_id = __t.uid(2)),
                 'dopo un invio fallito le righe si riprendono');

select public.be_cal_notify_done((select ids from c2 where user_id = __t.uid(2)), true);
reset role;
select __t.check((select count(*) from public.be_cal_notify where event_id in ('__t_e1','__t_e2') and user_id = __t.uid(2) and sent_at is not null) = 2,
                 'dopo l''invio le righe sono segnate come spedite');

-- 5) Un impegno spedito, eliminato e ripristinato non manda una seconda mail
select __t.as_user(1);
delete from public.be_cal_events where id = '__t_e1';
insert into public.be_cal_events (id, date, half, title, persons)
values ('__t_e1', current_date + 10, 'am', 'Montaggio', array['Alessandro','Luca']);
reset role;
select __t.check((select count(*) from public.be_cal_notify where event_id = '__t_e1' and user_id = __t.uid(2) and sent_at is null) = 0,
                 'ripristinare un impegno gia'' spedito non rimette in coda');

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
