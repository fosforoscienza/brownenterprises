-- =====================================================================
-- Brown Enterprises · area riservata
-- "Chi fa cosa": persone fuori dal team.
--
-- Prendono il posto della vecchia riga "Altri". Si aggiungono col "+",
-- diventano una riga del calendario come quelle del team e si possono
-- togliere. Ogni mese si decide se ci sono anche nel mese successivo:
-- months tiene le scelte, { "2026-11": true, "2026-12": false }. Un mese
-- senza scelta eredita l'ultima scelta fatta prima.
--
-- Togliere una persona non tocca gli impegni: il nome resta in
-- be_cal_events.persons.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo calendario.sql.
-- =====================================================================

create table if not exists public.be_cal_people (
  name       text primary key check (btrim(name) <> '' and length(name) <= 60),
  months     jsonb not null default '{}'::jsonb check (jsonb_typeof(months) = 'object'),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- "Marco" e "marco" sono la stessa persona
create unique index if not exists be_cal_people_name_lower_idx
  on public.be_cal_people (lower(name));

alter table public.be_cal_people enable row level security;

drop policy if exists be_cal_people_select on public.be_cal_people;
create policy be_cal_people_select on public.be_cal_people
  for select to authenticated
  using (true);

drop policy if exists be_cal_people_insert on public.be_cal_people;
create policy be_cal_people_insert on public.be_cal_people
  for insert to authenticated
  with check (true);

drop policy if exists be_cal_people_update on public.be_cal_people;
create policy be_cal_people_update on public.be_cal_people
  for update to authenticated
  using (true)
  with check (true);

drop policy if exists be_cal_people_delete on public.be_cal_people;
create policy be_cal_people_delete on public.be_cal_people
  for delete to authenticated
  using (true);

-- stessa funzione degli impegni (sql/calendario.sql)
drop trigger if exists be_cal_people_touch on public.be_cal_people;
create trigger be_cal_people_touch
  before update on public.be_cal_people
  for each row execute function public.be_cal_events_touch();
