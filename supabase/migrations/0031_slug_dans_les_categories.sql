-- =====================================================================
-- 0031 — Le slug voyage avec la catégorie
-- =====================================================================
-- L'application embarque désormais une icône par module. Encore faut-il
-- savoir LAQUELLE : le payload ne portait que l'identifiant, le nom et un
-- emoji.
--
-- Ni l'un ni l'autre ne convient comme clé. L'UUID est stable mais opaque —
-- l'écrire en dur dans le code obligerait à publier une version de l'app à
-- chaque réamorçage de la base. Le nom, lui, change : « Grocery » est le seul
-- intitulé anglais du lot et sera probablement renommé.
--
-- Le slug est fait pour ça : stable, lisible, déjà unique.

-- Suppression préalable OBLIGATOIRE : ajouter une colonne au résultat change
-- le type de retour, et `create or replace` le refuse — ERROR 42P13, « cannot
-- change return type of existing function ». La remplacer d'un bloc est le
-- seul chemin.
drop function if exists public.browsable_categories();

create function public.browsable_categories()
returns table (
  id        uuid,
  name      text,
  slug      text,
  icon      text,
  image_url text
)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.slug, c.icon, c.image_url
  from categories c
  where c.parent_id is null
    and c.is_active
    and exists (
      select 1
      from products p
      join merchants m on m.id = p.merchant_id
      left join categories enfant on enfant.id = p.category_id
      where p.is_available
        and m.is_approved
        and (p.category_id = c.id or enfant.parent_id = c.id)
    )
  order by c.sort_order, c.name
$$;

notify pgrst, 'reload schema';
