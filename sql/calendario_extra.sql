-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": le persone Extra si rinominano e si riordinano.
--
-- Extra sono tutte le persone fuori dai sei del team: quelle in
-- be_cal_people (aggiunte col "+") e i nomi scritti a mano negli impegni.
-- Ordine e nomi sono condivisi: chi li cambia li cambia per tutti.
--
-- - be_cal_people.position: l'ordine delle righe Extra. Chi non ce l'ha
--   (aggiunto dopo) va in fondo, nell'ordine in cui e' arrivato.
-- - be_cal_rename_person(vecchio, nuovo): cambia il nome nell'elenco e in
--   tutti gli impegni (be_cal_events.persons), in un colpo solo. Due Extra
--   in elenco non possono avere lo stesso nome; un nome scritto solo negli
--   impegni (un refuso, per esempio) si puo' invece unire a chi c'e' gia'.
-- - be_cal_order_people(nomi): salva l'ordine.
--
-- Le funzioni girano coi permessi di chi le chiama: valgono le policy di
-- be_cal_people e be_cal_events, gia' aperte a tutti gli utenti collegati.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo calendario.sql
-- e calendario_persone.sql.
-- =====================================================================

begin;

alter table public.be_cal_people add column if not exists position integer;

-- l'ordine di oggi: quello di arrivo
update public.be_cal_people p
   set position = s.n
  from (select name, row_number() over (order by created_at, name) - 1 as n
          from public.be_cal_people) s
 where s.name = p.name
   and p.position is null;

create or replace function public.be_cal_rename_person(old_name text, new_name text)
returns text
language plpgsql
security invoker
set search_path = public
as $$
declare
  n text := regexp_replace(btrim(coalesce(new_name, '')), '\s+', ' ', 'g');
begin
  if n = '' or length(n) > 60 then
    raise exception 'Il nome deve avere da 1 a 60 caratteri' using errcode = '22023';
  end if;
  if n = old_name then
    return n;
  end if;
  if exists (select 1 from public.be_cal_people where name = old_name) then
    -- due Extra in elenco non si uniscono: il nome nuovo deve essere libero
    if exists (select 1 from public.be_cal_people
                where lower(name) = lower(n) and lower(name) <> lower(old_name)) then
      raise exception '«%» c''è già tra gli Extra', n using errcode = '23505';
    end if;
  else
    -- un nome scritto solo negli impegni si unisce a chi e' gia' in elenco
    select name into n from public.be_cal_people where lower(name) = lower(n)
    union all select n
    limit 1;
  end if;

  update public.be_cal_people set name = n where name = old_name;

  update public.be_cal_events
     set persons = array_replace(persons, old_name, n)
   where old_name = any(persons);

  -- se il nome nuovo c'era gia' nello stesso impegno, resta una volta sola
  update public.be_cal_events e
     set persons = (select array_agg(x order by i)
                      from (select x, min(i) as i
                              from unnest(e.persons) with ordinality u(x, i)
                             group by x) d)
   where cardinality(array_positions(e.persons, n)) > 1;

  return n;
end $$;

create or replace function public.be_cal_order_people(names text[])
returns void
language sql
security invoker
set search_path = public
as $$
  update public.be_cal_people p
     set position = o.i - 1
    from unnest(names) with ordinality o(name, i)
   where p.name = o.name;
$$;

revoke all on function public.be_cal_rename_person(text, text) from public, anon;
revoke all on function public.be_cal_order_people(text[]) from public, anon;
grant execute on function public.be_cal_rename_person(text, text) to authenticated;
grant execute on function public.be_cal_order_people(text[]) to authenticated;

commit;
