-- =====================================================================
-- 0020 — Ne montrer que des catégories qui mènent quelque part
-- =====================================================================
-- Constaté sur un vrai téléphone : le client ouvre l'app, voit six
-- catégories, en touche une, et lit « Je n'ai rien trouvé dans cette
-- catégorie pour le moment ». Trois fois de suite. Puis il ferme l'app.
--
-- Deux causes se cumulaient.
--
-- D'ABORD LES CATÉGORIES VIDES. Sept catégories créées pendant les essais
-- d'avant la migration — Boissons, Boulangerie, Pharmacie, Viande & poisson,
-- Électronique, Maison, Épicerie — n'ont jamais reçu un seul produit. Et
-- trois catégories migrées n'en ont pas non plus : Coursier est un service,
-- Tovo Shop et Gaz sont des rayons jamais remplis chez 6ammart.
--
-- On ne les supprime pas : l'admin peut vouloir les garnir demain, et
-- supprimer une catégorie détacherait les produits qu'on y mettrait ensuite.
-- On cesse simplement de les proposer tant qu'elles sont vides.
--
-- ENSUITE LA HIÉRARCHIE. Aucun produit n'est attaché à une racine : la
-- migration a fait des modules 6ammart les racines, et de leurs 151
-- catégories les enfants. « Restaurants » compte 0 produit direct et 1 262
-- via ses 49 enfants. Toute lecture qui ignore les enfants ne trouve rien.

/*
 * Catégories proposables au client.
 *
 * Une racine n'est proposée que si elle mène à au moins un produit
 * disponible, directement ou par ses enfants. Proposer une impasse est la
 * façon la plus sûre de faire croire que l'application est vide.
 */
create or replace function public.browsable_categories()
returns table (
  id        uuid,
  name      text,
  icon      text,
  image_url text
)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.icon, c.image_url
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

/*
 * Les produits d'une catégorie, ses enfants compris.
 *
 * C'est le cœur du défaut : chercher `category_id = <racine>` ne remonte
 * jamais rien, puisque la migration attache les produits aux feuilles. Le
 * client touchait « Restaurants » et l'application lui répondait qu'elle
 * n'avait rien — avec 1 262 plats derrière.
 */
create or replace function public.category_products(
  p_category_id uuid,
  p_limite      integer default 12
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
  left join categories enfant on enfant.id = p.category_id
  where p.is_available
    and m.is_approved
    and (p.category_id = p_category_id or enfant.parent_id = p_category_id)
  -- Les boutiques ouvertes d'abord : proposer ce qu'on ne peut pas commander
  -- tout de suite est le meilleur moyen de perdre le client à l'étape
  -- suivante.
  order by m.is_open desc, p.name
  limit p_limite
$$;

notify pgrst, 'reload schema';
