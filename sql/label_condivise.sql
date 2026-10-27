-- =====================================================================
-- Brown Enterprises · area riservata
-- Label condivise: quelle che crea Alessandro valgono per tutto il team.
--
-- Le label restano di chi le crea (sql/label.sql), ma quelle nuove di
-- Alessandro nascono "shared": Lorenzo, Luca, Valeria, Mattia e Camilla
-- le vedono nella loro colonna di sinistra con dentro gli stessi
-- progetti, e ogni progetto che Alessandro ci mette viene condiviso con
-- loro in automatico. Solo Alessandro rinomina, elimina e riempie le sue
-- label condivise. Le label che aveva gia' restano private.
--
-- Il team si riconosce dall'email (@brown.internal), non dal nome
-- visualizzato, che ognuno puo' cambiare.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo label.sql.
-- =====================================================================

-- 1) Chi e' del team, e chi crea le label condivise
create or replace function public.be_label_team()
returns setof uuid
language sql
security definer
stable
set search_path = public, auth
as $$
  select u.id
    from auth.users u
   where lower(u.email) in (
     'alessandro@brown.internal', 'lorenzo@brown.internal', 'luca@brown.internal',
     'valeria@brown.internal',    'mattia@brown.internal',  'camilla@brown.internal'
   );
$$;

create or replace function public.be_is_label_team(p_user uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from public.be_label_team() t where t = p_user);
$$;

create or replace function public.be_label_sharer()
returns uuid
language sql
security definer
stable
set search_path = public, auth
as $$
  select u.id from auth.users u where lower(u.email) = 'alessandro@brown.internal';
$$;

revoke all on function public.be_label_team() from public;
revoke all on function public.be_is_label_team(uuid) from public;
revoke all on function public.be_label_sharer() from public;
grant execute on function public.be_label_team() to authenticated;
grant execute on function public.be_is_label_team(uuid) to authenticated;
grant execute on function public.be_label_sharer() to authenticated;

-- 2) Le label condivise
alter table public.be_labels
  add column if not exists shared boolean not null default false;

-- Lo decide il database, non il browser: nasce condivisa se la crea
-- Alessandro e non cambia piu'.
create or replace function public.be_labels_set_shared()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.shared := new.user_id = public.be_label_sharer();
  else
    new.shared := old.shared;
  end if;
  return new;
end;
$$;

drop trigger if exists be_labels_set_shared on public.be_labels;
create trigger be_labels_set_shared
  before insert or update on public.be_labels
  for each row execute function public.be_labels_set_shared();

drop policy if exists be_labels_select on public.be_labels;
create policy be_labels_select on public.be_labels
  for select to authenticated
  using (
    user_id = auth.uid()
    or (shared and public.be_is_label_team(auth.uid()))
  );

-- 3) I progetti dentro una label condivisa: chi e' del team vede le
--    assegnazioni di Alessandro (non le scelte private degli altri)
drop policy if exists be_project_labels_select on public.be_project_labels;
create policy be_project_labels_select on public.be_project_labels
  for select to authenticated
  using (
    user_id = auth.uid()
    or (
      public.be_is_label_team(auth.uid())
      and exists (
        select 1 from public.be_labels l
         where l.id = be_project_labels.label_id
           and l.shared
           and l.user_id = be_project_labels.user_id
      )
    )
  );

-- 4) Un progetto messo in una label condivisa si condivide col team.
--    Togliendolo dalla label le condivisioni restano.
create or replace function public.be_project_labels_share()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.be_labels l
     where l.id = new.label_id and l.shared and l.user_id = new.user_id
  ) then
    insert into public.be_project_shares (project_id, user_id)
    select new.project_id, t
      from public.be_label_team() t
      join public.be_projects p on p.id = new.project_id
     where t <> p.owner_id
    on conflict (project_id, user_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists be_project_labels_share on public.be_project_labels;
create trigger be_project_labels_share
  after insert or update of label_id on public.be_project_labels
  for each row execute function public.be_project_labels_share();
