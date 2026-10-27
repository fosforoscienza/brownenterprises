-- =====================================================================
-- Brown Enterprises · area riservata
-- Categorie del team, «Personale», Preferiti e Archiviati.
--
-- Le categorie prendono il posto delle label nella colonna di sinistra.
-- Sono una sola lista, uguale per tutto il team: un progetto sta in una
-- categoria per tutti, e chiunque del team crea, rinomina ed elimina le
-- categorie e ci sposta dentro i progetti.
--
-- Un progetto nuovo e' del team: lo vedono e ci lavorano tutti quelli
-- con l'email @brown.internal, senza bisogno di condividerlo a mano.
-- Chi lo mette in «Personale» lo vede da solo, e puo' condividerlo con
-- singole persone (be_project_shares, come prima). Chi non e' del team
-- crea solo progetti personali.
--
-- Archiviare e' una scelta del team (archived_at): il progetto finisce
-- in «Archiviati» per tutti e, ripristinato, torna nella sua categoria.
-- La stellina dei Preferiti invece e' privata di ognuno.
--
-- Le aree di lavoro (In progettazione / In corso / Amministrazione)
-- restano come sono, e cambiarle resta al proprietario.
--
-- I progetti esistenti: quelli gia' condivisi con qualcuno diventano del
-- team, quelli che vedeva solo il proprietario finiscono nel suo
-- «Personale». Le label usate dai progetti del team diventano categorie
-- (prima la label condivisa, poi quella del proprietario). Le tabelle
-- be_labels e be_project_labels restano dove sono, ma l'app non le usa
-- piu'.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo label.sql e
-- label_condivise.sql.
-- =====================================================================

begin;

-- 1) Chi e' del team: lo dice il dominio dell'email, non il nome
create or replace function public.be_is_team(p_user uuid)
returns boolean
language sql
security definer
stable
set search_path = public, auth
as $$
  select exists (
    select 1 from auth.users u
     where u.id = p_user and lower(u.email) like '%@brown.internal'
  );
$$;

create or replace function public.be_team()
returns setof uuid
language sql
security definer
stable
set search_path = public, auth
as $$
  select u.id from auth.users u where lower(u.email) like '%@brown.internal';
$$;

revoke all on function public.be_is_team(uuid) from public;
revoke all on function public.be_team() from public;
grant execute on function public.be_is_team(uuid) to authenticated;
grant execute on function public.be_team() to authenticated;

-- 2) Le categorie, una lista sola per tutti
create table if not exists public.be_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (btrim(name) <> ''),
  position   integer not null default 0,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists be_categories_name_uidx
  on public.be_categories (lower(btrim(name)));

alter table public.be_categories enable row level security;

-- i nomi li legge chiunque sia collegato: anche chi e' fuori dal team
-- vede in che categoria sta un progetto condiviso con lui
drop policy if exists be_categories_select on public.be_categories;
create policy be_categories_select on public.be_categories
  for select to authenticated
  using (true);

drop policy if exists be_categories_insert on public.be_categories;
create policy be_categories_insert on public.be_categories
  for insert to authenticated
  with check (public.be_is_team(auth.uid()));

drop policy if exists be_categories_update on public.be_categories;
create policy be_categories_update on public.be_categories
  for update to authenticated
  using (public.be_is_team(auth.uid()))
  with check (public.be_is_team(auth.uid()));

drop policy if exists be_categories_delete on public.be_categories;
create policy be_categories_delete on public.be_categories
  for delete to authenticated
  using (public.be_is_team(auth.uid()));

-- 3) Colonne nuove dei progetti, e il recupero dei dati che c'erano.
--    Il blocco gira solo la prima volta (finche' manca la colonna
--    personal): rieseguendo lo script non si rifanno le scelte.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'be_projects' and column_name = 'personal'
  ) then
    -- nasce true: nessun progetto diventa visibile a tutti per sbaglio
    alter table public.be_projects add column personal boolean not null default true;
    alter table public.be_projects add column category_id uuid
      references public.be_categories(id) on delete set null;
    alter table public.be_projects add column archived_at timestamptz;

    -- gia' condiviso con qualcuno (e di uno del team) = del team
    update public.be_projects p
       set personal = false
     where public.be_is_team(p.owner_id)
       and exists (select 1 from public.be_project_shares s where s.project_id = p.id);

    if to_regclass('public.be_project_labels') is not null then
      -- una label per progetto: prima quella condivisa, poi quella del
      -- proprietario, poi la piu' vecchia
      create temporary table be_tmp_pick on commit drop as
      select distinct on (p.id) p.id as project_id, btrim(l.name) as name
        from public.be_projects p
        join public.be_project_labels pl on pl.project_id = p.id
        join public.be_labels l on l.id = pl.label_id
       where not p.personal
       order by p.id, l.shared desc, (pl.user_id = p.owner_id) desc, pl.created_at;

      insert into public.be_categories (name, position, created_by)
      select n.name, (row_number() over (order by lower(n.name)))::int - 1, null
        from (select distinct on (lower(name)) name from be_tmp_pick order by lower(name), name) n
      on conflict do nothing;

      update public.be_projects p
         set category_id = c.id
        from be_tmp_pick t
        join public.be_categories c on lower(btrim(c.name)) = lower(t.name)
       where t.project_id = p.id;
    end if;

    alter table public.be_projects alter column personal set default false;
  end if;
end $$;

create index if not exists be_projects_category_idx
  on public.be_projects (category_id);

-- 4) Chi vede un progetto: il proprietario, chi l'ha avuto condiviso e,
--    se non e' personale, tutto il team. Le due funzioni sono quelle che
--    usano gia' le policy di colonne, card, condivisioni e Archivio.
create or replace function public.be_is_project_member(p_project_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.be_projects p
     where p.id = p_project_id
       and (
         p.owner_id = auth.uid()
         or (not p.personal and public.be_is_team(auth.uid()))
         or exists (
           select 1 from public.be_project_shares s
            where s.project_id = p.id and s.user_id = auth.uid()
         )
       )
  );
$$;

create or replace function public.be_can_access_project(p_project uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select public.be_is_project_member(p_project);
$$;

drop policy if exists "members view projects" on public.be_projects;
create policy "members view projects" on public.be_projects
  for select to authenticated
  using (
    owner_id = auth.uid()
    or (not personal and public.be_is_team(auth.uid()))
    or exists (
      select 1 from public.be_project_shares s
       where s.project_id = be_projects.id and s.user_id = auth.uid()
    )
  );

-- Sui progetti del team chiunque del team cambia categoria e archivio;
-- il resto (nome, area, Personale) lo controlla il trigger qui sotto.
drop policy if exists "owner updates project" on public.be_projects;
drop policy if exists "team updates project" on public.be_projects;
create policy "team updates project" on public.be_projects
  for update to authenticated
  using (owner_id = auth.uid() or (not personal and public.be_is_team(auth.uid())))
  with check (owner_id = auth.uid() or (not personal and public.be_is_team(auth.uid())));

create or replace function public.be_projects_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and auth.uid() is not null and auth.uid() <> old.owner_id then
    if new.name is distinct from old.name
       or new.owner_id is distinct from old.owner_id
       or new.area is distinct from old.area
       or new.personal is distinct from old.personal then
      raise exception 'Solo il proprietario puo'' cambiare nome, area o «Personale» del progetto'
        using errcode = '42501';
    end if;
  end if;
  -- chi non e' del team non ha progetti del team
  if not public.be_is_team(new.owner_id) then
    new.personal := true;
  end if;
  -- «Personale» e' una categoria a se'
  if new.personal then
    new.category_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists be_projects_guard on public.be_projects;
create trigger be_projects_guard
  before insert or update on public.be_projects
  for each row execute function public.be_projects_guard();

-- 5) Preferiti: la stellina e' di chi la mette
create table if not exists public.be_project_favorites (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.be_projects(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, project_id)
);

alter table public.be_project_favorites enable row level security;

drop policy if exists be_project_favorites_select on public.be_project_favorites;
create policy be_project_favorites_select on public.be_project_favorites
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists be_project_favorites_insert on public.be_project_favorites;
create policy be_project_favorites_insert on public.be_project_favorites
  for insert to authenticated
  with check (user_id = auth.uid() and public.be_can_access_project(project_id));

drop policy if exists be_project_favorites_delete on public.be_project_favorites;
create policy be_project_favorites_delete on public.be_project_favorites
  for delete to authenticated
  using (user_id = auth.uid());

commit;
