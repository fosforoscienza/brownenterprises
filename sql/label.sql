-- =====================================================================
-- Brown Enterprises · area riservata
-- Label della colonna di sinistra.
--
-- Ogni utente crea le proprie label e ci mette dentro i progetti che
-- vede (propri o condivisi con lui): le label e le assegnazioni sono
-- private, quindi lo stesso progetto puo' stare sotto label diverse
-- per persone diverse. Un progetto sta in una sola label per utente.
--
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

-- 0) Helper: l'utente corrente puo' accedere al progetto?
--    (gia' creato da sql/archivio.sql, qui e' idempotente)
create or replace function public.be_can_access_project(p_project uuid)
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
        p.owner_id = auth.uid()
        or exists (
          select 1 from public.be_project_shares s
          where s.project_id = p.id and s.user_id = auth.uid()
        )
      )
  );
$$;

-- 1) Le label appartengono a un singolo utente
create table if not exists public.be_labels (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null check (btrim(name) <> ''),
  position   integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists be_labels_user_idx
  on public.be_labels (user_id, position);

create unique index if not exists be_labels_user_name_uidx
  on public.be_labels (user_id, lower(btrim(name)));

alter table public.be_labels enable row level security;

drop policy if exists be_labels_select on public.be_labels;
create policy be_labels_select on public.be_labels
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists be_labels_insert on public.be_labels;
create policy be_labels_insert on public.be_labels
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists be_labels_update on public.be_labels;
create policy be_labels_update on public.be_labels
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists be_labels_delete on public.be_labels;
create policy be_labels_delete on public.be_labels
  for delete to authenticated
  using (user_id = auth.uid());

-- 2) Assegnazione progetto -> label, privata per ogni utente
create table if not exists public.be_project_labels (
  user_id    uuid not null references auth.users(id) on delete cascade,
  project_id uuid not null references public.be_projects(id) on delete cascade,
  label_id   uuid not null references public.be_labels(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, project_id)
);

create index if not exists be_project_labels_label_idx
  on public.be_project_labels (label_id);

alter table public.be_project_labels enable row level security;

drop policy if exists be_project_labels_select on public.be_project_labels;
create policy be_project_labels_select on public.be_project_labels
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists be_project_labels_insert on public.be_project_labels;
create policy be_project_labels_insert on public.be_project_labels
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.be_can_access_project(project_id)
    and exists (
      select 1 from public.be_labels l
      where l.id = label_id and l.user_id = auth.uid()
    )
  );

drop policy if exists be_project_labels_update on public.be_project_labels;
create policy be_project_labels_update on public.be_project_labels
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and public.be_can_access_project(project_id)
    and exists (
      select 1 from public.be_labels l
      where l.id = label_id and l.user_id = auth.uid()
    )
  );

drop policy if exists be_project_labels_delete on public.be_project_labels;
create policy be_project_labels_delete on public.be_project_labels
  for delete to authenticated
  using (user_id = auth.uid());

-- 3) Recupero dei vecchi "spazi": i progetti che erano nello spazio
--    Bandi finiscono in una label "Bandi" del rispettivo proprietario.
--    Il blocco viene saltato se la colonna space non esiste piu'.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name  = 'be_projects'
      and column_name = 'space'
  ) then
    insert into public.be_labels (user_id, name, position)
    select distinct p.owner_id, 'Bandi', 0
      from public.be_projects p
     where p.space = 'bandi'
    on conflict do nothing;

    insert into public.be_project_labels (user_id, project_id, label_id)
    select p.owner_id, p.id, l.id
      from public.be_projects p
      join public.be_labels l
        on l.user_id = p.owner_id
       and lower(btrim(l.name)) = 'bandi'
     where p.space = 'bandi'
    on conflict (user_id, project_id) do nothing;
  end if;
end $$;

-- 4) Facoltativo: la colonna space non e' piu' usata dall'applicazione.
--    Togli i commenti alle due righe seguenti per eliminarla.
-- alter table public.be_projects drop constraint if exists be_projects_space_check;
-- alter table public.be_projects drop column if exists space;
