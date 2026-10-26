-- =====================================================================
-- Brown Enterprises · area riservata
-- Calendario "Chi fa cosa" condiviso dal team.
--
-- Prima gli impegni vivevano solo nel browser di chi li scriveva: ognuno
-- vedeva i suoi. Qui diventano una tabella unica, letta e scritta da tutti
-- gli utenti collegati. Una riga = un impegno, che puo' riguardare piu'
-- persone (persons) e occupare la mattina, il pomeriggio o tutta la
-- giornata (half), anche su piu' giorni (date_end, per le ferie).
--
-- be_cal_feeds tiene il link segreto con cui Apple Calendar si abbona
-- agli impegni di una persona (vedi api/cal-feed.js).
--
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

-- 1) Impegni
create table if not exists public.be_cal_events (
  id           text primary key,
  date         date not null,
  date_end     date,                                  -- null = stesso giorno
  half         text not null default 'am',            -- am | pm | day
  start_time   text,                                  -- 'HH:MM' oppure null
  end_time     text,
  title        text not null check (btrim(title) <> ''),
  persons      text[] not null default '{}',
  kind         text not null default 'lavoro',        -- lavoro | extra | ferie
  status       text not null default 'confermato',    -- confermato | da_confermare
  project_id   uuid references public.be_projects(id) on delete set null,
  project_name text,                                  -- copia del nome: lo vede anche chi non ha il progetto
  notes        text,
  series_id    text,                                  -- impegni ricorrenti: stessa serie
  recur        jsonb,                                 -- { days:[1..7], from:'YYYY-MM-DD', to:'YYYY-MM-DD' }
  source       text not null default 'mario',         -- mario | apple
  created_by   uuid default auth.uid() references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint be_cal_events_half_check   check (half in ('am','pm','day')),
  constraint be_cal_events_kind_check   check (kind in ('lavoro','extra','ferie')),
  constraint be_cal_events_status_check check (status in ('confermato','da_confermare')),
  constraint be_cal_events_source_check check (source in ('mario','apple')),
  constraint be_cal_events_range_check  check (date_end is null or date_end >= date)
);

create index if not exists be_cal_events_date_idx
  on public.be_cal_events (date);
create index if not exists be_cal_events_series_idx
  on public.be_cal_events (series_id) where series_id is not null;
create index if not exists be_cal_events_persons_idx
  on public.be_cal_events using gin (persons);

alter table public.be_cal_events enable row level security;

drop policy if exists be_cal_events_select on public.be_cal_events;
create policy be_cal_events_select on public.be_cal_events
  for select to authenticated
  using (true);

drop policy if exists be_cal_events_insert on public.be_cal_events;
create policy be_cal_events_insert on public.be_cal_events
  for insert to authenticated
  with check (true);

drop policy if exists be_cal_events_update on public.be_cal_events;
create policy be_cal_events_update on public.be_cal_events
  for update to authenticated
  using (true)
  with check (true);

drop policy if exists be_cal_events_delete on public.be_cal_events;
create policy be_cal_events_delete on public.be_cal_events
  for delete to authenticated
  using (true);

create or replace function public.be_cal_events_touch()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists be_cal_events_touch on public.be_cal_events;
create trigger be_cal_events_touch
  before update on public.be_cal_events
  for each row execute function public.be_cal_events_touch();

-- 2) Link di abbonamento per Apple Calendar: uno per utente
create table if not exists public.be_cal_feeds (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  person     text not null check (btrim(person) <> ''),
  token      text not null unique check (length(token) >= 32),
  created_at timestamptz not null default now()
);

alter table public.be_cal_feeds enable row level security;

drop policy if exists be_cal_feeds_select on public.be_cal_feeds;
create policy be_cal_feeds_select on public.be_cal_feeds
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists be_cal_feeds_insert on public.be_cal_feeds;
create policy be_cal_feeds_insert on public.be_cal_feeds
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists be_cal_feeds_update on public.be_cal_feeds;
create policy be_cal_feeds_update on public.be_cal_feeds
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists be_cal_feeds_delete on public.be_cal_feeds;
create policy be_cal_feeds_delete on public.be_cal_feeds
  for delete to authenticated
  using (user_id = auth.uid());

-- 3) Il feed: Apple Calendar non fa login, presenta solo il token.
--    La funzione gira con i permessi del proprietario e restituisce gli
--    impegni della persona legata al token, esclusi quelli che arrivano
--    proprio da Apple (altrimenti tornerebbero indietro doppi).
create or replace function public.be_cal_feed(p_token text)
returns setof public.be_cal_events
language sql
security definer
stable
set search_path = public
as $$
  select e.*
    from public.be_cal_events e
    join public.be_cal_feeds f on f.token = p_token
   where length(coalesce(p_token, '')) >= 32
     and f.person = any (e.persons)
     and e.source <> 'apple'
     and coalesce(e.date_end, e.date) >= current_date - 90
   order by e.date, e.start_time nulls first;
$$;

revoke all on function public.be_cal_feed(text) from public;
grant execute on function public.be_cal_feed(text) to anon, authenticated;
