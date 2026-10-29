-- =====================================================================
-- Brown Enterprises · area riservata
-- Task: destinatari, data di inizio, registro delle attivita' e
-- riepilogo email giornaliero.
--
--  - Una card puo' avere uno o piu' destinatari (be_card_assignees),
--    scelti fra le persone che vedono il progetto.
--  - Oltre alla scadenza (due_date, sql/scadenza.sql) una card puo' avere
--    una data di inizio (start_date): solo inizio, inizio e fine, solo fine.
--  - Ogni cosa che succede a una card (assegnata, spostata di lista,
--    modificata, eliminata) finisce in be_card_events con l'elenco di chi
--    la deve sapere: i destinatari, tranne chi ha fatto la modifica.
--  - Ognuno indica in be_notify_prefs l'indirizzo a cui ricevere, una volta
--    al giorno, il riepilogo di quello che e' successo ai suoi task. La
--    funzione Vercel api/task-digest lo legge con la chiave service_role
--    (be_task_digest_pending) e spedisce le email.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo scadenza.sql
-- e categorie.sql (be_is_team, be_projects.personal).
-- =====================================================================

-- 0) Helper: una persona (non per forza quella collegata) vede il progetto?
--    Stesse regole di be_is_project_member (sql/categorie.sql): proprietario,
--    tutto il team per i progetti non personali, condivisioni.
create or replace function public.be_user_can_access_project(p_project uuid, p_user uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.be_projects p
    where p.id = p_project
      and (
        p.owner_id = p_user
        or (not p.personal and public.be_is_team(p_user))
        or exists (
          select 1 from public.be_project_shares s
          where s.project_id = p.id and s.user_id = p_user
        )
      )
  );
$$;

create or replace function public.be_can_access_card(p_card uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.be_cards c
    where c.id = p_card and public.be_can_access_project(c.project_id)
  );
$$;

revoke all on function public.be_user_can_access_project(uuid, uuid) from public;
revoke all on function public.be_can_access_card(uuid) from public;
grant execute on function public.be_user_can_access_project(uuid, uuid) to authenticated;
grant execute on function public.be_can_access_card(uuid) to authenticated;

-- 1) Data di inizio
alter table public.be_cards
  add column if not exists start_date date;

comment on column public.be_cards.start_date is
  'Data di inizio della card: da sola, oppure con due_date come fine.';

-- 2) Destinatari
create table if not exists public.be_card_assignees (
  card_id    uuid not null references public.be_cards(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  added_by   uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (card_id, user_id)
);

create index if not exists be_card_assignees_user_idx
  on public.be_card_assignees (user_id);

alter table public.be_card_assignees enable row level security;

drop policy if exists be_card_assignees_select on public.be_card_assignees;
create policy be_card_assignees_select on public.be_card_assignees
  for select to authenticated
  using (public.be_can_access_card(card_id));

-- si assegna solo a chi vede il progetto della card
drop policy if exists be_card_assignees_insert on public.be_card_assignees;
create policy be_card_assignees_insert on public.be_card_assignees
  for insert to authenticated
  with check (
    public.be_can_access_card(card_id)
    and public.be_user_can_access_project(
      (select c.project_id from public.be_cards c where c.id = card_id), user_id)
  );

drop policy if exists be_card_assignees_delete on public.be_card_assignees;
create policy be_card_assignees_delete on public.be_card_assignees
  for delete to authenticated
  using (public.be_can_access_card(card_id));

-- 3) Registro delle attivita'. card_id non e' una foreign key: l'evento
--    "eliminata" deve sopravvivere alla card.
create table if not exists public.be_card_events (
  id         bigint generated always as identity primary key,
  card_id    uuid not null,
  project_id uuid references public.be_projects(id) on delete cascade,
  actor_id   uuid references auth.users(id) on delete set null,
  kind       text not null check (kind in ('assigned','unassigned','moved','updated','deleted')),
  title      text not null default '',
  detail     jsonb not null default '{}'::jsonb,
  recipients uuid[] not null default '{}',
  created_at timestamptz not null default now()
);

create index if not exists be_card_events_created_idx
  on public.be_card_events (created_at);
create index if not exists be_card_events_recipients_idx
  on public.be_card_events using gin (recipients);

alter table public.be_card_events enable row level security;

-- ognuno legge gli eventi che lo riguardano; li scrivono solo i trigger
drop policy if exists be_card_events_select on public.be_card_events;
create policy be_card_events_select on public.be_card_events
  for select to authenticated
  using (auth.uid() = any (recipients));

-- I destinatari della card, tranne chi ha fatto la modifica
create or replace function public.be_card_recipients(p_card uuid)
returns uuid[]
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(array_agg(a.user_id), '{}')
    from public.be_card_assignees a
   where a.card_id = p_card
     and a.user_id is distinct from auth.uid();
$$;

revoke all on function public.be_card_recipients(uuid) from public;

create or replace function public.be_cards_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rcpt    uuid[];
  changed text[] := '{}';
begin
  if tg_op = 'DELETE' then
    rcpt := public.be_card_recipients(old.id);
    if cardinality(rcpt) > 0 then
      insert into public.be_card_events (card_id, project_id, actor_id, kind, title, recipients)
      values (old.id, old.project_id, auth.uid(), 'deleted', old.title, rcpt);
    end if;
    return old;
  end if;

  rcpt := public.be_card_recipients(new.id);
  if cardinality(rcpt) = 0 then return new; end if;

  if new.column_id is distinct from old.column_id then
    insert into public.be_card_events (card_id, project_id, actor_id, kind, title, detail, recipients)
    values (new.id, new.project_id, auth.uid(), 'moved', new.title,
            jsonb_build_object(
              'from', (select k.name from public.be_columns k where k.id = old.column_id),
              'to',   (select k.name from public.be_columns k where k.id = new.column_id)),
            rcpt);
  end if;

  if new.title is distinct from old.title then changed := changed || 'titolo'::text; end if;
  if new.priority is distinct from old.priority then changed := changed || 'priorità'::text; end if;
  if new.start_date is distinct from old.start_date
     or new.due_date is distinct from old.due_date then changed := changed || 'date'::text; end if;
  -- done_at cambia da solo quando la card entra o esce da Done: lo
  -- racconta gia' l'evento "moved"
  if new.done_at is distinct from old.done_at
     and new.column_id is not distinct from old.column_id then changed := changed || 'completamento'::text; end if;

  if cardinality(changed) > 0 then
    insert into public.be_card_events (card_id, project_id, actor_id, kind, title, detail, recipients)
    values (new.id, new.project_id, auth.uid(), 'updated', new.title,
            jsonb_build_object('fields', to_jsonb(changed),
                               'old_title', case when new.title is distinct from old.title then old.title end),
            rcpt);
  end if;
  return new;
end;
$$;

drop trigger if exists be_cards_log_update on public.be_cards;
create trigger be_cards_log_update
  after update on public.be_cards
  for each row execute function public.be_cards_log();

-- before: dopo la cancellazione i destinatari se ne vanno a cascata
drop trigger if exists be_cards_log_delete on public.be_cards;
create trigger be_cards_log_delete
  before delete on public.be_cards
  for each row execute function public.be_cards_log();

create or replace function public.be_card_assignees_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.be_card_assignees;
  c public.be_cards;
begin
  if tg_op = 'INSERT' then r := new; else r := old; end if;
  -- assegnarsi da soli non genera avvisi
  if r.user_id is not distinct from auth.uid() then return r; end if;
  select * into c from public.be_cards where id = r.card_id;
  -- card appena eliminata (cascata): c'e' gia' l'evento "deleted"
  if not found then return r; end if;
  insert into public.be_card_events (card_id, project_id, actor_id, kind, title, recipients)
  values (c.id, c.project_id, auth.uid(),
          case when tg_op = 'INSERT' then 'assigned' else 'unassigned' end,
          c.title, array[r.user_id]);
  return r;
end;
$$;

drop trigger if exists be_card_assignees_log on public.be_card_assignees;
create trigger be_card_assignees_log
  after insert or delete on public.be_card_assignees
  for each row execute function public.be_card_assignees_log();

-- 4) Preferenze del riepilogo email. Gli account del team hanno indirizzi
--    @brown.internal, che non ricevono posta: ognuno indica il suo.
create table if not exists public.be_notify_prefs (
  user_id        uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  email          text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  daily_digest   boolean not null default true,
  last_digest_at timestamptz,
  updated_at     timestamptz not null default now()
);

alter table public.be_notify_prefs enable row level security;

drop policy if exists be_notify_prefs_select on public.be_notify_prefs;
create policy be_notify_prefs_select on public.be_notify_prefs
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists be_notify_prefs_insert on public.be_notify_prefs;
create policy be_notify_prefs_insert on public.be_notify_prefs
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists be_notify_prefs_update on public.be_notify_prefs;
create policy be_notify_prefs_update on public.be_notify_prefs
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 5) Il riepilogo: per ogni persona con l'email attiva, gli eventi
--    dall'ultimo invio (al massimo gli ultimi 7 giorni). Solo service_role.
create or replace function public.be_task_digest_pending()
returns table (user_id uuid, email text, display_name text, until timestamptz, events jsonb)
language sql
security definer
stable
set search_path = public
as $$
  with cutoff as (select now() as t)
  select n.user_id, n.email, coalesce(pr.display_name, ''), (select t from cutoff),
         jsonb_agg(jsonb_build_object(
           'kind', e.kind, 'title', e.title, 'detail', e.detail, 'at', e.created_at,
           'project', coalesce(p.name, ''), 'actor', coalesce(ap.display_name, '')
         ) order by p.name, e.created_at)
    from public.be_notify_prefs n
    join public.be_card_events e
      on n.user_id = any (e.recipients)
     and e.created_at > greatest(coalesce(n.last_digest_at, '-infinity'), now() - interval '7 days')
     and e.created_at <= (select t from cutoff)
    left join public.be_profiles pr on pr.id = n.user_id
    left join public.be_projects p  on p.id = e.project_id
    left join public.be_profiles ap on ap.id = e.actor_id
   where n.daily_digest and n.email is not null
   group by n.user_id, n.email, pr.display_name;
$$;

create or replace function public.be_task_digest_mark(p_user uuid, p_until timestamptz)
returns void
language sql
security definer
set search_path = public
as $$
  update public.be_notify_prefs
     set last_digest_at = p_until
   where user_id = p_user;
  delete from public.be_card_events where created_at < now() - interval '90 days';
$$;

revoke all on function public.be_task_digest_pending() from public, anon, authenticated;
revoke all on function public.be_task_digest_mark(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.be_task_digest_pending() to service_role;
grant execute on function public.be_task_digest_mark(uuid, timestamptz) to service_role;

notify pgrst, 'reload schema';
