-- =====================================================================
-- Brown Enterprises · area riservata
-- Il coordinatore dei progetti, e l'eliminazione che non perde niente.
--
-- 1) Coordinatore: be_profiles.coordinator (Alessandro). Quando qualcun
--    altro crea un progetto del team, al coordinatore compare un avviso:
--    conferma la categoria o la cambia. be_projects.reviewed_at resta
--    vuoto finche' il coordinatore non l'ha visto; lo puo' riempire solo
--    lui. I progetti che ci sono gia' contano come visti.
-- 2) Eliminare: un progetto del team lo elimina il proprietario o il
--    coordinatore (un Personale solo il proprietario).
--    be_delete_project(progetto, destinazione) prima passa alla
--    destinazione schede (nelle liste con lo stesso nome, create se
--    mancano), elementi dell'Archivio e impegni di "Chi fa cosa", poi
--    elimina il progetto. Tutto o niente.
-- 3) I file dell'Archivio restano dove sono nello storage: si leggono e si
--    cancellano anche se la cartella e' di un progetto che non c'e' piu',
--    purche' l'elemento dell'Archivio sia di un progetto accessibile.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo categorie.sql
-- e archivio.sql.
-- =====================================================================

begin;

-- 1) coordinatore ------------------------------------------------------

alter table public.be_profiles add column if not exists coordinator boolean not null default false;

update public.be_profiles p
   set coordinator = true
  from auth.users u
 where u.id = p.id
   and lower(u.email) = 'alessandro@brown.internal'
   and not p.coordinator;

create or replace function public.be_is_coordinator(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select coordinator from public.be_profiles where id = uid), false)
$$;
revoke all on function public.be_is_coordinator(uuid) from public, anon;
grant execute on function public.be_is_coordinator(uuid) to authenticated;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'be_projects'
                    and column_name = 'reviewed_at') then
    alter table public.be_projects add column reviewed_at timestamptz;
    -- quelli che ci sono gia' il coordinatore li conosce
    update public.be_projects set reviewed_at = now();
  end if;
end $$;

/* reviewed_at: pieno se il progetto lo crea il coordinatore; per il resto
   lo cambia solo lui */
create or replace function public.be_projects_review()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.reviewed_at := case when public.be_is_coordinator() then now() end;
  elsif new.reviewed_at is distinct from old.reviewed_at and not public.be_is_coordinator() then
    new.reviewed_at := old.reviewed_at;
  end if;
  return new;
end $$;

drop trigger if exists be_projects_review on public.be_projects;
create trigger be_projects_review
  before insert or update on public.be_projects
  for each row execute function public.be_projects_review();

-- 2) eliminare ---------------------------------------------------------

drop policy if exists "owner deletes project" on public.be_projects;
drop policy if exists "owner or coordinator deletes project" on public.be_projects;
create policy "owner or coordinator deletes project" on public.be_projects
  for delete to authenticated
  using (owner_id = auth.uid() or (not personal and public.be_is_coordinator()));

create or replace function public.be_delete_project(p_project uuid, p_target uuid default null)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  c record;
  dest uuid;
  last_pos double precision;
begin
  if not exists (select 1 from public.be_projects where id = p_project) then
    raise exception 'Progetto non trovato' using errcode = 'P0002';
  end if;

  if p_target is not null then
    if p_target = p_project then
      raise exception 'Scegli un progetto diverso da quello da eliminare' using errcode = '22023';
    end if;
    if not exists (select 1 from public.be_projects where id = p_target) then
      raise exception 'Progetto di destinazione non trovato' using errcode = 'P0002';
    end if;

    -- schede: nella lista con lo stesso nome, in fondo; se non c'e' si crea
    for c in select id, name from public.be_columns where project_id = p_project order by position loop
      select id into dest from public.be_columns
       where project_id = p_target and lower(btrim(name)) = lower(btrim(c.name))
       order by position limit 1;
      if dest is null then
        insert into public.be_columns (project_id, name, position)
        values (p_target, c.name,
                (select coalesce(max(position), 0) + 1 from public.be_columns where project_id = p_target))
        returning id into dest;
      end if;
      select coalesce(max(position), 0) into last_pos from public.be_cards where column_id = dest;
      update public.be_cards
         set project_id = p_target, column_id = dest, position = last_pos + position + 1
       where column_id = c.id;
    end loop;

    update public.be_library_items
       set project_id = p_target,
           position = position + (select coalesce(max(position), 0) + 1
                                    from public.be_library_items where project_id = p_target)
     where project_id = p_project;

    update public.be_cal_events set project_id = p_target where project_id = p_project;
  end if;

  -- schede, liste e Archivio rimasti se ne vanno col progetto
  delete from public.be_projects where id = p_project;
  if not found then
    raise exception 'Non puoi eliminare questo progetto' using errcode = '42501';
  end if;
end $$;
revoke all on function public.be_delete_project(uuid, uuid) from public, anon;
grant execute on function public.be_delete_project(uuid, uuid) to authenticated;

-- 3) file dell'Archivio passati a un altro progetto ---------------------

drop policy if exists be_library_storage_select on storage.objects;
create policy be_library_storage_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'be-library'
    and (
      ((storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
       and public.be_can_access_project(((storage.foldername(name))[1])::uuid))
      or exists (select 1 from public.be_library_items i
                  where i.storage_path = storage.objects.name
                    and public.be_can_access_project(i.project_id))
    )
  );

drop policy if exists be_library_storage_delete on storage.objects;
create policy be_library_storage_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'be-library'
    and (
      ((storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
       and public.be_can_access_project(((storage.foldername(name))[1])::uuid))
      or exists (select 1 from public.be_library_items i
                  where i.storage_path = storage.objects.name
                    and public.be_can_access_project(i.project_id))
    )
  );

commit;
