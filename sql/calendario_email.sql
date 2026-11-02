-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": una mail a chi riceve un impegno da qualcun altro.
--
-- Quando qualcuno crea un impegno per altre persone del team, o ne
-- aggiunge a un impegno che c'era gia', ognuna di loro riceve una mail
-- con i dettagli. Chi crea l'impegno non la riceve, e nemmeno gli Extra:
-- non hanno un account.
--
--  - Il nome in be_cal_events.persons diventa un account come fa il login
--    (beEmailForName in js/be-config.js): "Luca" -> luca@brown.internal.
--    L'indirizzo vero e' quello di be_notify_prefs.email (sql/task.sql),
--    lo stesso del riepilogo dei task; cal_assign permette di spegnere
--    solo queste mail.
--  - Un trigger mette in coda (be_cal_notify) una riga per persona e
--    impegno. La funzione Vercel api/cal-notify svuota la coda: la chiama
--    il browser subito dopo il salvataggio e, per quello che resta indietro,
--    il cron di ogni mattina. Ogni persona riceve una mail sola con tutti
--    gli impegni in coda: un impegno ricorrente, un "duplica" o una
--    modifica di piu' impegni non diventano una raffica.
--  - Una persona riceve al massimo una mail per impegno: spostarlo,
--    cambiarne l'orario o togliere e rimettere la persona non ne manda
--    altre. Non partono mail per gli impegni gia' passati, per quelli
--    importati da Apple Calendar, ne' per le modifiche fatte senza un
--    utente collegato (editor SQL, script).
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo task.sql,
-- calendario.sql, calendario_extra_nomi.sql e luogo.sql.
-- =====================================================================

begin;

-- 1) Preferenza: la mail degli impegni si puo' spegnere a parte
alter table public.be_notify_prefs
  add column if not exists cal_assign boolean not null default true;

comment on column public.be_notify_prefs.cal_assign is
  'Mail quando qualcun altro ti assegna un impegno in Chi fa cosa.';

-- 2) La coda. event_id non e' una foreign key: le righe gia' spedite
--    devono sopravvivere all'impegno, cosi' un impegno eliminato e poi
--    ripristinato non manda una seconda mail.
create table if not exists public.be_cal_notify (
  id         bigint generated always as identity primary key,
  event_id   text not null,
  user_id    uuid not null references auth.users(id) on delete cascade,
  actor_id   uuid references auth.users(id) on delete set null,
  kind       text not null check (kind in ('created','added')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at    timestamptz
);

create unique index if not exists be_cal_notify_once_idx
  on public.be_cal_notify (event_id, user_id);
create index if not exists be_cal_notify_pending_idx
  on public.be_cal_notify (created_at) where sent_at is null;

-- nessuna policy: la scrive il trigger, la legge api/cal-notify con la
-- chiave service_role
alter table public.be_cal_notify enable row level security;

-- L'account di un nome del calendario, come al login. Gli Extra non ne
-- hanno uno: per loro e' null.
create or replace function public.be_cal_person_user(p_name text)
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select u.id from auth.users u
   where lower(u.email) = lower(btrim(p_name)) || '@brown.internal'
$$;

revoke all on function public.be_cal_person_user(text) from public, anon, authenticated;

-- 3) Il trigger: le persone nuove dell'impegno, tranne chi lo salva
create or replace function public.be_cal_events_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  me    uuid := auth.uid();
  added text[];
begin
  if me is null or new.source <> 'mario'
     or coalesce(new.date_end, new.date) < (now() at time zone 'Europe/Rome')::date then
    return null;
  end if;
  if tg_op = 'INSERT' then
    added := new.persons;
  else
    select coalesce(array_agg(x), '{}') into added
      from unnest(new.persons) x
     where not (x = any (old.persons));
  end if;
  if cardinality(added) = 0 then return null; end if;

  insert into public.be_cal_notify (event_id, user_id, actor_id, kind)
  select new.id, u.uid, me, case when tg_op = 'INSERT' then 'created' else 'added' end
    from (select distinct public.be_cal_person_user(x) as uid from unnest(added) x) u
    join public.be_notify_prefs n on n.user_id = u.uid
   where u.uid is not null
     and u.uid <> me
     and n.email is not null
     and n.cal_assign
  on conflict do nothing;
  return null;
end $$;

-- after: i nomi sono gia' stati sistemati da be_cal_events_people
drop trigger if exists be_cal_events_notify on public.be_cal_events;
create trigger be_cal_events_notify
  after insert or update of persons on public.be_cal_events
  for each row execute function public.be_cal_events_notify();

-- 4) Per api/cal-notify: prende in carico quello che c'e' da spedire e lo
--    restituisce raggruppato per persona. Prima butta via le righe che non
--    vanno piu' spedite: impegno eliminato o passato, persona tolta
--    dall'impegno, mail spenta. Una riga presa in carico da piu' di dieci
--    minuti (invio interrotto) torna disponibile.
create or replace function public.be_cal_notify_claim()
returns table (user_id uuid, email text, display_name text, ids bigint[], events jsonb)
language sql
security definer
volatile
set search_path = public
as $$
  delete from public.be_cal_notify q
   where (q.sent_at is not null and q.sent_at < now() - interval '120 days')
      or (q.sent_at is null and (
            q.created_at < now() - interval '7 days'
            or not exists (
              select 1 from public.be_notify_prefs n
               where n.user_id = q.user_id and n.email is not null and n.cal_assign)
            or not exists (
              select 1 from public.be_cal_events e
               where e.id = q.event_id
                 and coalesce(e.date_end, e.date) >= (now() at time zone 'Europe/Rome')::date
                 and exists (select 1 from unnest(e.persons) x
                              where public.be_cal_person_user(x) = q.user_id))));

  with claimed as (
    update public.be_cal_notify q
       set claimed_at = now()
     where q.id in (
       select c.id from public.be_cal_notify c
        where c.sent_at is null
          and (c.claimed_at is null or c.claimed_at < now() - interval '10 minutes')
        for update skip locked)
    returning q.*
  )
  select c.user_id, n.email, coalesce(pr.display_name, ''),
         array_agg(c.id order by c.id),
         jsonb_agg(jsonb_build_object(
           'id', e.id, 'change', c.kind, 'title', e.title,
           'date', e.date, 'date_end', e.date_end, 'half', e.half,
           'start_time', e.start_time, 'end_time', e.end_time,
           'kind', e.kind, 'status', e.status, 'project', e.project_name,
           'location', e.location, 'notes', e.notes,
           'series_id', e.series_id, 'recur', e.recur, 'persons', e.persons,
           'actor', coalesce(ap.display_name, '')
         ) order by e.date, e.start_time nulls first, e.id)
    from claimed c
    join public.be_cal_events e   on e.id = c.event_id
    join public.be_notify_prefs n on n.user_id = c.user_id
    left join public.be_profiles pr on pr.id = c.user_id
    left join public.be_profiles ap on ap.id = c.actor_id
   group by c.user_id, n.email, pr.display_name;
$$;

-- Dopo l'invio: spedite (p_sent) oppure di nuovo in coda per il prossimo giro
create or replace function public.be_cal_notify_done(p_ids bigint[], p_sent boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update public.be_cal_notify
     set sent_at    = case when p_sent then now() end,
         claimed_at = case when p_sent then claimed_at end
   where id = any (p_ids)
     and sent_at is null;
$$;

revoke all on function public.be_cal_notify_claim() from public, anon, authenticated;
revoke all on function public.be_cal_notify_done(bigint[], boolean) from public, anon, authenticated;
grant execute on function public.be_cal_notify_claim() to service_role;
grant execute on function public.be_cal_notify_done(bigint[], boolean) to service_role;

commit;

notify pgrst, 'reload schema';
