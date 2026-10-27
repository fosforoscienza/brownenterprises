-- =====================================================================
-- Test di sql/categorie.sql sul database vero, senza lasciare tracce:
-- tutto avviene in una transazione che alla fine viene annullata.
--
--   ssh mac-mini 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < tests/categorie.test.sql
--
-- Ogni controllo che fallisce interrompe lo script con un errore.
-- Servono due utenti @brown.internal e uno fuori dal team in auth.users.
-- =====================================================================

begin;

-- aiutanti, in uno schema che sparisce con il rollback
create schema __t;
grant usage on schema __t to anon, authenticated;

select set_config('t.u1', (select id::text from auth.users where email like '%@brown.internal' order by created_at limit 1), true),
       set_config('t.u2', (select id::text from auth.users where email like '%@brown.internal' order by created_at offset 1 limit 1), true),
       set_config('t.u3', (select id::text from auth.users where email not like '%@brown.internal' order by created_at limit 1), true);

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

select __t.check(__t.uid(1) is not null and __t.uid(2) is not null and __t.uid(3) is not null
                 and __t.uid(1) <> __t.uid(2), 'ci sono due utenti del team e uno da fuori');

-- ---------------------------------------------------------------------
-- 1) categorie: le gestisce il team, le leggono tutti

select __t.as_user(1);
insert into public.be_categories (id, name, position) values ('00000000-0000-4000-8000-0000000c0001', '__Cat test', 99);
select __t.check((select created_by from public.be_categories where id = '00000000-0000-4000-8000-0000000c0001') = __t.uid(1),
  'categoria creata da uno del team');
select __t.must_fail($$insert into public.be_categories (name) values ('  __cat TEST ')$$, '23505', 'nome doppio rifiutato (maiuscole e spazi non contano)');

select __t.as_user(2);
update public.be_categories set name = '__Cat test 2' where id = '00000000-0000-4000-8000-0000000c0001';
select __t.check((select name from public.be_categories where id = '00000000-0000-4000-8000-0000000c0001') = '__Cat test 2',
  'un altro del team la rinomina');

select __t.as_user(3);
select __t.check((select count(*) from public.be_categories where id = '00000000-0000-4000-8000-0000000c0001') = 1,
  'chi e'' fuori dal team legge le categorie');
select __t.must_fail($$insert into public.be_categories (name) values ('__Da fuori')$$, '42501', 'chi e'' fuori dal team non crea categorie');
update public.be_categories set name = 'x' where id = '00000000-0000-4000-8000-0000000c0001';
delete from public.be_categories where id = '00000000-0000-4000-8000-0000000c0001';
reset role;
select __t.check((select name from public.be_categories where id = '00000000-0000-4000-8000-0000000c0001') = '__Cat test 2',
  'chi e'' fuori dal team non rinomina ne'' elimina');

-- ---------------------------------------------------------------------
-- 2) un progetto nuovo e' del team; uno personale lo vede solo chi lo crea

select __t.as_user(1);
insert into public.be_projects (id, name, owner_id, category_id)
values ('00000000-0000-4000-8000-0000000a0001', '__Del team', __t.uid(1), '00000000-0000-4000-8000-0000000c0001');
insert into public.be_projects (id, name, owner_id, personal)
values ('00000000-0000-4000-8000-0000000a0002', '__Personale', __t.uid(1), true);
select __t.check((select not personal from public.be_projects where id = '00000000-0000-4000-8000-0000000a0001'),
  'di default il progetto e'' del team');

select __t.as_user(2);
select __t.check((select count(*) from public.be_projects where id = '00000000-0000-4000-8000-0000000a0001') = 1,
  'il team vede il progetto senza condivisioni');
select __t.check((select count(*) from public.be_projects where id = '00000000-0000-4000-8000-0000000a0002') = 0,
  'il team non vede il Personale di un altro');
insert into public.be_columns (id, project_id, name, position)
values ('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-0000000a0001', 'To Do', 0);
select __t.check((select count(*) from public.be_columns where id = '00000000-0000-4000-8000-0000000b0001') = 1,
  'il team lavora sulle liste di un progetto del team');
select __t.must_fail($$insert into public.be_columns (project_id, name, position) values ('00000000-0000-4000-8000-0000000a0002', 'x', 0)$$,
  '42501', 'il team non scrive nel Personale di un altro');

select __t.as_user(3);
select __t.check((select count(*) from public.be_projects where id::text like '00000000-0000-4000-8000-0000000a%') = 0,
  'chi e'' fuori dal team non vede nessuno dei due');

-- condiviso a mano: il Personale si apre a una persona sola
select __t.as_user(1);
insert into public.be_project_shares (project_id, user_id) values ('00000000-0000-4000-8000-0000000a0002', __t.uid(3));
select __t.as_user(3);
select __t.check((select count(*) from public.be_projects where id = '00000000-0000-4000-8000-0000000a0002') = 1,
  'il Personale condiviso lo vede chi l''ha ricevuto');
select __t.as_user(2);
select __t.check((select count(*) from public.be_projects where id = '00000000-0000-4000-8000-0000000a0002') = 0,
  '...e non il resto del team');

-- chi e' fuori dal team crea solo progetti personali
select __t.as_user(3);
insert into public.be_projects (id, name, owner_id, personal, category_id)
values ('00000000-0000-4000-8000-0000000a0003', '__Da fuori', __t.uid(3), false, '00000000-0000-4000-8000-0000000c0001');
select __t.check((select personal and category_id is null from public.be_projects where id = '00000000-0000-4000-8000-0000000a0003'),
  'il progetto di chi e'' fuori dal team nasce personale');

-- ---------------------------------------------------------------------
-- 3) categoria e archivio li cambia il team; il resto il proprietario

select __t.as_user(2);
update public.be_projects set category_id = null, archived_at = now() where id = '00000000-0000-4000-8000-0000000a0001';
select __t.check((select category_id is null and archived_at is not null from public.be_projects where id = '00000000-0000-4000-8000-0000000a0001'),
  'un altro del team sposta e archivia');
select __t.must_fail($$update public.be_projects set name = 'x' where id = '00000000-0000-4000-8000-0000000a0001'$$,
  '42501', 'un altro del team non rinomina');
select __t.must_fail($$update public.be_projects set area = 'amministrazione' where id = '00000000-0000-4000-8000-0000000a0001'$$,
  '42501', 'un altro del team non cambia area');
select __t.must_fail($$update public.be_projects set personal = true where id = '00000000-0000-4000-8000-0000000a0001'$$,
  '42501', 'un altro del team non lo mette in Personale');

select __t.as_user(3);
update public.be_projects set archived_at = now() where id = '00000000-0000-4000-8000-0000000a0002';
select __t.check((select archived_at is null from public.be_projects where id = '00000000-0000-4000-8000-0000000a0002'),
  'chi ha ricevuto un Personale non lo archivia');

select __t.as_user(1);
update public.be_projects set category_id = '00000000-0000-4000-8000-0000000c0001', archived_at = null
 where id = '00000000-0000-4000-8000-0000000a0001';
update public.be_projects set personal = true, category_id = '00000000-0000-4000-8000-0000000c0001'
 where id = '00000000-0000-4000-8000-0000000a0001';
select __t.check((select personal and category_id is null from public.be_projects where id = '00000000-0000-4000-8000-0000000a0001'),
  'il proprietario lo porta in Personale, e la categoria si svuota');
update public.be_projects set personal = false, category_id = '00000000-0000-4000-8000-0000000c0001'
 where id = '00000000-0000-4000-8000-0000000a0001';

-- eliminare una categoria non elimina i progetti
select __t.as_user(2);
delete from public.be_categories where id = '00000000-0000-4000-8000-0000000c0001';
select __t.check((select category_id is null from public.be_projects where id = '00000000-0000-4000-8000-0000000a0001'),
  'categoria eliminata: il progetto resta, senza categoria');

-- ---------------------------------------------------------------------
-- 4) Preferiti: privati di ognuno

select __t.as_user(2);
insert into public.be_project_favorites (project_id) values ('00000000-0000-4000-8000-0000000a0001');
select __t.check((select user_id from public.be_project_favorites where project_id = '00000000-0000-4000-8000-0000000a0001') = __t.uid(2),
  'la stellina e'' di chi la mette');
select __t.must_fail($$insert into public.be_project_favorites (project_id) values ('00000000-0000-4000-8000-0000000a0002')$$,
  '42501', 'niente stellina su un progetto che non si vede');
select __t.must_fail($$insert into public.be_project_favorites (user_id, project_id) values (__t.uid(1), '00000000-0000-4000-8000-0000000a0001')$$,
  '42501', 'niente stellina a nome di un altro');

select __t.as_user(1);
select __t.check((select count(*) from public.be_project_favorites where project_id = '00000000-0000-4000-8000-0000000a0001') = 0,
  'le stelline degli altri non si vedono');
delete from public.be_project_favorites where project_id = '00000000-0000-4000-8000-0000000a0001';

reset role;
select __t.check((select count(*) from public.be_project_favorites where project_id = '00000000-0000-4000-8000-0000000a0001') = 1,
  'le stelline degli altri non si tolgono');

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
