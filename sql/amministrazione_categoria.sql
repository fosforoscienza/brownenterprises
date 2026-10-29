-- =====================================================================
-- Brown Enterprises · area riservata
-- «Amministrazione» da area di lavoro diventa una categoria del team.
--
-- In alto restano due aree, In progettazione e In corso. Nasce la
-- categoria «Amministrazione», che come tutte le categorie vede l'intero
-- team (si puo' poi spostare dove si vuole trascinandola). I progetti
-- del team che stavano nell'area Amministrazione entrano in questa
-- categoria, anche se prima erano in un'altra, e passano all'area In
-- corso. Gli archiviati entrano nella categoria e restano archiviati:
-- ripristinati, tornano li'. Quelli in «Personale» restano dove sono
-- (il Personale non ha categoria) e passano anche loro a In corso.
--
-- Il vincolo be_projects_area_check accetta ancora 'amministrazione':
-- un'app rimasta nella cache del browser non va in errore, e l'app
-- nuova mostra comunque un progetto con quell'area in In corso.
--
-- Eseguire una sola volta nell'editor SQL di Supabase, dopo
-- area_progetti.sql e categorie.sql. Rieseguirlo non fa danni.
-- =====================================================================

begin;

-- 1) la categoria, in fondo alla lista (se non c'e' gia')
insert into public.be_categories (name, position, created_by)
select 'Amministrazione', coalesce(max(position), -1) + 1, null
  from public.be_categories
on conflict do nothing;

-- 2) i progetti del team dell'area Amministrazione ci entrano
update public.be_projects p
   set category_id = c.id
  from public.be_categories c
 where lower(btrim(c.name)) = 'amministrazione'
   and p.area = 'amministrazione'
   and not p.personal;

-- 3) e tutti passano all'area In corso
update public.be_projects
   set area = 'in_corso'
 where area = 'amministrazione';

commit;
