-- =====================================================================
-- 0025 — Les rayons d'une boutique
-- =====================================================================
-- Ouvrir une boutique renvoyait ses douze premiers produits, par ordre
-- alphabétique, sans le dire. Mesuré sur le catalogue réel : 36 boutiques
-- sur 77 en ont davantage. GALAXIE en compte 131, ROYAL GRILL 108,
-- Restaurant Albarka Food 97.
--
-- Le client ne voyait donc qu'une fraction de l'offre, et rien ne lui
-- indiquait qu'il en manquait. Pire : ordre alphabétique, donc toujours les
-- mêmes douze — les « 1/2 poulet » et les « Assiettes » avant tout le reste.
--
-- Relever la limite ne suffirait pas : un carrousel de 131 articles n'est
-- pas plus utilisable que douze. 6ammart organisait déjà ces produits en
-- rayons — GALAXIE en a 9, Albarka Food 19 — et la migration a conservé ce
-- rattachement. On s'en sert.

/*
 * Les rayons d'une boutique, avec ce qu'ils contiennent.
 *
 * Seuls les rayons qui ont au moins un produit disponible : proposer une
 * section vide est la même faute que proposer une catégorie vide, à un
 * niveau plus bas.
 */
create or replace function public.merchant_categories(p_merchant_id uuid)
returns table (
  id        uuid,
  name      text,
  icon      text,
  image_url text,
  produits  integer
)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.icon, c.image_url, count(p.id)::integer
  from products p
  join categories c on c.id = p.category_id
  where p.merchant_id = p_merchant_id
    and p.is_available
  group by c.id, c.name, c.icon, c.image_url
  order by count(p.id) desc, c.name
$$;

/*
 * Les produits d'une boutique, éventuellement d'un seul rayon.
 *
 * @param p_category_id null pour tout la boutique. Sert au cas où elle n'a
 *        qu'un rayon, ou trop peu de produits pour qu'un détour par les
 *        rayons se justifie.
 */
create or replace function public.merchant_products(
  p_merchant_id uuid,
  p_category_id uuid default null,
  p_limite      integer default 40
)
returns table (
  id            uuid,
  name          text,
  description   text,
  image_url     text,
  price         integer,
  is_available  boolean,
  merchant_id   uuid,
  merchant_name text
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.description, p.image_url, p.price, p.is_available,
         p.merchant_id, m.name
  from products p
  join merchants m on m.id = p.merchant_id
  where p.merchant_id = p_merchant_id
    and p.is_available
    and m.is_approved
    and (p_category_id is null or p.category_id = p_category_id)
  order by p.name
  limit p_limite
$$;

notify pgrst, 'reload schema';
