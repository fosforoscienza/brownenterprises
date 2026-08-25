-- =====================================================================
-- Brown Enterprises · area riservata
-- Biblioteca: documenti (file caricati) e link (Google Drive & co.)
-- Eseguire una sola volta nell'editor SQL di Supabase.
-- =====================================================================

-- 1) Helper: l'utente corrente può accedere al progetto?
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

-- 2) Tabella degli elementi della Biblioteca
create table if not exists public.be_library_items (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid not null references public.be_projects(id) on delete cascade,
  kind         text not null check (kind in ('file','link')),
  title        text not null,
  url          text,
  storage_path text,
  mime_type    text,
  size_bytes   bigint,
  position     integer not null default 0,
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint be_library_items_payload check (
    (kind = 'link' and url is not null) or
    (kind = 'file' and storage_path is not null)
  )
);

create index if not exists be_library_items_project_idx
  on public.be_library_items (project_id, position);

alter table public.be_library_items enable row level security;

drop policy if exists be_library_items_select on public.be_library_items;
create policy be_library_items_select on public.be_library_items
  for select to authenticated
  using (public.be_can_access_project(project_id));

drop policy if exists be_library_items_insert on public.be_library_items;
create policy be_library_items_insert on public.be_library_items
  for insert to authenticated
  with check (public.be_can_access_project(project_id));

drop policy if exists be_library_items_update on public.be_library_items;
create policy be_library_items_update on public.be_library_items
  for update to authenticated
  using (public.be_can_access_project(project_id))
  with check (public.be_can_access_project(project_id));

drop policy if exists be_library_items_delete on public.be_library_items;
create policy be_library_items_delete on public.be_library_items
  for delete to authenticated
  using (public.be_can_access_project(project_id));

-- 3) Bucket privato per i file caricati (path: <project_id>/<nome-file>)
insert into storage.buckets (id, name, public, file_size_limit)
values ('be-library', 'be-library', false, 52428800)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

-- 4) Policy sullo storage: stesso perimetro di accesso del progetto
drop policy if exists be_library_storage_select on storage.objects;
create policy be_library_storage_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'be-library'
    and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
    and public.be_can_access_project(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists be_library_storage_insert on storage.objects;
create policy be_library_storage_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'be-library'
    and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
    and public.be_can_access_project(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists be_library_storage_delete on storage.objects;
create policy be_library_storage_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'be-library'
    and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
    and public.be_can_access_project(((storage.foldername(name))[1])::uuid)
  );
