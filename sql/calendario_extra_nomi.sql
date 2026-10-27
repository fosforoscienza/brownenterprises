-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": ogni nome fuori dal team e' un Extra.
--
-- Negli impegni sono rimasti nomi scritti a mano o arrivati dai vecchi CSV
-- (Franci, Vero, Tommi, ...) che non sono in be_cal_people: non si vedevano
-- nella colonna di sinistra e non si potevano scegliere. Da qui in poi
-- chiunque non sia uno dei sei soci e' un Extra in elenco.
--
-- - I nomi scritti con maiuscole diverse diventano uno ("tommaso" ->
--   "Tommaso", "luca" -> "Luca").
-- - Ogni altro nome entra in be_cal_people, in fondo, nell'ordine in cui e'
--   comparso: c'e' dal mese del suo primo impegno e non c'e' piu' dal mese
--   dopo l'ultimo (si cambia in "Chi c'e'").
-- - Un trigger fa lo stesso per gli impegni che arriveranno, anche da
--   versioni vecchie dell'app.
-- - be_cal_rename_person ha un terzo argomento, merge: con true unisce due
--   Extra in elenco (impegni e mesi passano a quello col nome nuovo).
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo
-- calendario_extra.sql.
-- =====================================================================

begin;

/* I sei soci, col nome scritto bene; null per chiunque altro */
create or replace function public.be_cal_team_name(n text)
returns text
language sql
immutable
set search_path = public
as $$
  select t from unnest(array['Alessandro','Lorenzo','Luca','Valeria','Mattia','Camilla']) t
   where lower(t) = lower(btrim(n))
$$;

/* Il nome come va scritto: quello del socio, o quello gia' in elenco */
create or replace function public.be_cal_person_name(n text)
returns text
language sql
stable
set search_path = public
as $$
  select coalesce(public.be_cal_team_name(n),
                  (select p.name from public.be_cal_people p where lower(p.name) = lower(btrim(n))),
                  regexp_replace(btrim(n), '\s+', ' ', 'g'))
$$;

/* Prima di salvare un impegno: nomi scritti bene, una volta sola, e chi
   non e' in elenco ci entra (c'e' dal mese dell'impegno) */
create or replace function public.be_cal_events_people()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  x text;
  fixed text[] := '{}';
begin
  if new.persons is null then
    return new;
  end if;
  foreach x in array new.persons loop
    if btrim(x) = '' then continue; end if;
    x := public.be_cal_person_name(x);
    if public.be_cal_team_name(x) is null
       and not exists (select 1 from public.be_cal_people p where lower(p.name) = lower(x)) then
      insert into public.be_cal_people (name, months, position)
      values (x, jsonb_build_object(to_char(new.date, 'YYYY-MM'), true),
              (select coalesce(max(position), -1) + 1 from public.be_cal_people))
      on conflict do nothing;
    end if;
    if not x = any(fixed) then
      fixed := fixed || x;
    end if;
  end loop;
  new.persons := fixed;
  return new;
end $$;

drop trigger if exists be_cal_events_people on public.be_cal_events;
create trigger be_cal_events_people
  before insert or update of persons on public.be_cal_events
  for each row execute function public.be_cal_events_people();

-- i nomi rimasti: chi non e' in elenco ci entra, dal primo all'ultimo mese
insert into public.be_cal_people (name, months, position)
select n.name,
       jsonb_build_object(to_char(n.primo, 'YYYY-MM'), true,
                          to_char(n.ultimo + interval '1 month', 'YYYY-MM'), false),
       (select coalesce(max(position), -1) from public.be_cal_people)
         + row_number() over (order by n.primo, n.name)
  from (select distinct on (lower(x)) regexp_replace(btrim(x), '\s+', ' ', 'g') as name,
               min(e.date) over (partition by lower(x)) as primo,
               max(coalesce(e.date_end, e.date)) over (partition by lower(x)) as ultimo
          from public.be_cal_events e, unnest(e.persons) x
         where btrim(x) <> ''
           and public.be_cal_team_name(x) is null
           and not exists (select 1 from public.be_cal_people p where lower(p.name) = lower(x))
         order by lower(x), x) n
on conflict do nothing;

-- e negli impegni ogni nome scritto come in elenco (il trigger lo sistema)
update public.be_cal_events e
   set persons = e.persons
 where exists (select 1 from unnest(e.persons) x
                where x <> public.be_cal_person_name(x) or btrim(x) = '')
    or cardinality(e.persons) <> (select count(distinct x) from unnest(e.persons) x);

/* Rinominare, ora anche unendo due Extra in elenco (merge = true) */
drop function if exists public.be_cal_rename_person(text, text);
create or replace function public.be_cal_rename_person(old_name text, new_name text, merge boolean default false)
returns text
language plpgsql
security invoker
set search_path = public
as $$
declare
  n text := regexp_replace(btrim(coalesce(new_name, '')), '\s+', ' ', 'g');
  target public.be_cal_people;
  source public.be_cal_people;
begin
  if n = '' or length(n) > 60 then
    raise exception 'Il nome deve avere da 1 a 60 caratteri' using errcode = '22023';
  end if;
  if public.be_cal_team_name(n) is not null then
    raise exception '«%» è uno dei soci: scegli un altro nome', public.be_cal_team_name(n) using errcode = '22023';
  end if;
  if n = old_name then
    return n;
  end if;
  select * into source from public.be_cal_people where name = old_name;
  select * into target from public.be_cal_people
   where lower(name) = lower(n) and lower(name) <> lower(old_name);

  if target.name is not null then
    if source.name is not null and not merge then
      raise exception '«%» c''è già tra gli Extra', target.name using errcode = '23505';
    end if;
    n := target.name;
    -- unendo, in ogni mese c'e' se c'era almeno uno dei due
    if source.name is not null then
      update public.be_cal_people t
         set months = (select coalesce(jsonb_object_agg(k, coalesce((t.months ->> k)::boolean, false)
                                                         or coalesce((source.months ->> k)::boolean, false)), '{}'::jsonb)
                         from (select jsonb_object_keys(t.months) k
                               union select jsonb_object_keys(source.months)) ks)
       where t.name = target.name;
      delete from public.be_cal_people where name = old_name;
    end if;
  else
    update public.be_cal_people set name = n where name = old_name;
  end if;

  -- il trigger degli impegni toglie i doppioni
  update public.be_cal_events
     set persons = array_replace(persons, old_name, n)
   where old_name = any(persons);

  return n;
end $$;

revoke all on function public.be_cal_rename_person(text, text, boolean) from public, anon;
grant execute on function public.be_cal_rename_person(text, text, boolean) to authenticated;

commit;
