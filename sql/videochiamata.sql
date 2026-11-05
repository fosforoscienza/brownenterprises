-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": il link della videochiamata di un impegno.
--
-- Le videochiamate si fanno con la web app call.fosforoscienza.it: un
-- organizzatore la programma li', copia il link e lo incolla nell'impegno.
-- video_url tiene quel link; il vincolo accetta solo i link di quella web
-- app (https://call.fosforoscienza.it/call/...), cosi' nella mail e nel
-- calendario di Apple non finisce un indirizzo qualsiasi.
--
-- be_cal_feed (sql/calendario.sql) restituisce tutte le colonne: il feed
-- per Apple Calendar lo passa come URL. be_cal_notify_claim
-- (sql/calendario_email.sql) viene riscritta uguale, con il link in piu'
-- per la mail.
--
-- Le policy di be_cal_events valgono anche per la colonna nuova.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo calendario.sql,
-- luogo.sql e calendario_email.sql.
-- =====================================================================

begin;

alter table public.be_cal_events
  add column if not exists video_url text;

alter table public.be_cal_events
  drop constraint if exists be_cal_events_video_url_check;
alter table public.be_cal_events
  add constraint be_cal_events_video_url_check check (
    video_url is null or (
      length(video_url) <= 300
      and video_url ~ '^https://call\.fosforoscienza\.it/call/[A-Za-z0-9-]+/?$'
    )
  );

comment on column public.be_cal_events.video_url is
  'Link della videochiamata su call.fosforoscienza.it.';

-- La mail di "Chi fa cosa" con il link della videochiamata: stessa funzione
-- di sql/calendario_email.sql, con video_url fra i dettagli
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
           'location', e.location, 'video_url', e.video_url, 'notes', e.notes,
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

revoke all on function public.be_cal_notify_claim() from public, anon, authenticated;
grant execute on function public.be_cal_notify_claim() to service_role;

commit;

notify pgrst, 'reload schema';
