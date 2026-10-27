-- =====================================================================
-- Test di sql/coordinatore.sql sul database vero, senza lasciare tracce:
-- tutto avviene in una transazione che alla fine viene annullata.
--
--   ssh mac-mini 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < tests/coordinatore.test.sql
--
-- Ogni controllo che fallisce interrompe lo script con un errore.
-- Servono il coordinatore (alessandro@brown.internal) e un altro utente
-- @brown.internal in auth.users.
-- =====================================================================

begin;

create schema __t;
grant usage on schema __t to anon, authenticated;

select set_config('t.u1', (select id::text from auth.users where lower(email) = 'alessandro@brown.internal'), true),
       set_config('t.u2', (select id::text from auth.users where email like '%@brown.internal'
                                                      and lower(email) <> 'alessandro@brown.internal'
                            order by created_at limit 1), true);

create function __t.uid(n int) returns uuid language sql stable as $$
  select current_setting('t.u' || n)::uuid
$$;

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

select __t.check(__t.uid(1) is not null and __t.uid(2) is not null, 'ci sono il coordinatore e un altro del team');
select __t.check(public.be_is_coordinator(__t.uid(1)) and not public.be_is_coordinator(__t.uid(2)),
  'Alessandro è il coordinatore, l''altro no');

-- ---------------------------------------------------------------------
-- 1) progetti nuovi da far vedere al coordinatore

select __t.as_user(2);
insert into public.be_projects (id, name, owner_id) values
  ('00000000-0000-4000-8000-0000000d0001', '__Nuovo', __t.uid(2)),
  ('00000000-0000-4000-8000-0000000d0002', '__Destinazione', __t.uid(2));
select __t.check((select reviewed_at is null from public.be_projects where id = '00000000-0000-4000-8000-0000000d0001'),
  'il progetto di un altro aspetta il coordinatore');
update public.be_projects set reviewed_at = now() where id = '00000000-0000-4000-8000-0000000d0001';
select __t.check((select reviewed_at is null from public.be_projects where id = '00000000-0000-4000-8000-0000000d0001'),
  'chi non è coordinatore non lo segna come visto');

select __t.as_user(1);
update public.be_projects set reviewed_at = now() where id = '00000000-0000-4000-8000-0000000d0001';
select __t.check((select reviewed_at is not null from public.be_projects where id = '00000000-0000-4000-8000-0000000d0001'),
  'il coordinatore lo segna come visto');
insert into public.be_projects (id, name, owner_id) values ('00000000-0000-4000-8000-0000000d0003', '__Suo', __t.uid(1));
select __t.check((select reviewed_at is not null from public.be_projects where id = '00000000-0000-4000-8000-0000000d0003'),
  'i progetti del coordinatore sono già visti');

-- ---------------------------------------------------------------------
-- 2) eliminare passando schede, Archivio e impegni a un altro progetto

select __t.as_user(2);
insert into public.be_columns (id, project_id, name, position) values
  ('00000000-0000-4000-8000-0000000f0001', '00000000-0000-4000-8000-0000000d0001', 'To Do', 0),
  ('00000000-0000-4000-8000-0000000f0002', '00000000-0000-4000-8000-0000000d0001', 'Idee', 1),
  ('00000000-0000-4000-8000-0000000f0003', '00000000-0000-4000-8000-0000000d0002', 'to do', 0);
insert into public.be_cards (id, project_id, column_id, title, position) values
  ('00000000-0000-4000-8000-0000000c0d01', '00000000-0000-4000-8000-0000000d0001', '00000000-0000-4000-8000-0000000f0001', '__a', 0),
  ('00000000-0000-4000-8000-0000000c0d02', '00000000-0000-4000-8000-0000000d0001', '00000000-0000-4000-8000-0000000f0002', '__b', 0),
  ('00000000-0000-4000-8000-0000000c0d03', '00000000-0000-4000-8000-0000000d0002', '00000000-0000-4000-8000-0000000f0003', '__c', 0);
insert into public.be_library_items (project_id, kind, title, url, position)
values ('00000000-0000-4000-8000-0000000d0001', 'link', '__link', 'https://example.com', 0);
insert into public.be_cal_events (id, date, half, title, persons, kind, status, source, project_id)
values ('00000000-0000-4000-8000-0000000e0d01', '2099-02-01', 'am', '__ev', array['Luca'], 'lavoro', 'confermato', 'mario',
        '00000000-0000-4000-8000-0000000d0001');

select __t.must_fail($$select public.be_delete_project('00000000-0000-4000-8000-0000000d0001', '00000000-0000-4000-8000-0000000d0001')$$,
  '22023', 'non si passa tutto al progetto stesso');

select __t.as_user(1);
select public.be_delete_project('00000000-0000-4000-8000-0000000d0001', '00000000-0000-4000-8000-0000000d0002');
reset role;
select __t.check(not exists (select 1 from public.be_projects where id = '00000000-0000-4000-8000-0000000d0001'),
  'il coordinatore elimina il progetto di un altro');
select __t.check((select column_id from public.be_cards where id = '00000000-0000-4000-8000-0000000c0d01') = '00000000-0000-4000-8000-0000000f0003',
  'la scheda va nella lista con lo stesso nome');
select __t.check((select c.name from public.be_cards k join public.be_columns c on c.id = k.column_id
                   where k.id = '00000000-0000-4000-8000-0000000c0d02') = 'Idee'
                 and (select project_id from public.be_cards where id = '00000000-0000-4000-8000-0000000c0d02') = '00000000-0000-4000-8000-0000000d0002',
  'se la lista non c''è, si crea');
select __t.check((select array_agg(title order by position) from public.be_cards
                   where column_id = '00000000-0000-4000-8000-0000000f0003') = array['__c', '__a'],
  'le schede spostate vanno in fondo');
select __t.check((select project_id from public.be_library_items where title = '__link') = '00000000-0000-4000-8000-0000000d0002',
  'l''Archivio passa al progetto scelto');
select __t.check((select project_id from public.be_cal_events where id = '00000000-0000-4000-8000-0000000e0d01') = '00000000-0000-4000-8000-0000000d0002',
  'gli impegni passano al progetto scelto');

-- ---------------------------------------------------------------------
-- 3) chi può eliminare

select __t.as_user(1);
insert into public.be_projects (id, name, owner_id, personal) values ('00000000-0000-4000-8000-0000000d0004', '__Personale A', __t.uid(1), true);
select __t.as_user(2);
insert into public.be_projects (id, name, owner_id, personal) values ('00000000-0000-4000-8000-0000000d0005', '__Personale B', __t.uid(2), true);
select __t.must_fail($$select public.be_delete_project('00000000-0000-4000-8000-0000000d0003')$$,
  '42501', 'chi non è proprietario né coordinatore non elimina');
select __t.as_user(1);
select __t.must_fail($$select public.be_delete_project('00000000-0000-4000-8000-0000000d0005')$$,
  'P0002', 'il coordinatore non elimina il Personale di un altro (non lo vede nemmeno)');
select public.be_delete_project('00000000-0000-4000-8000-0000000d0004');
select __t.check(not exists (select 1 from public.be_projects where id = '00000000-0000-4000-8000-0000000d0004'),
  'senza niente da spostare si elimina e basta');

rollback;

\echo
\echo TUTTI I TEST SQL PASSATI (transazione annullata: nel database non resta niente)
