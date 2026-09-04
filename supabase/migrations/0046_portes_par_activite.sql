-- =====================================================================
-- 0046 — Des portes qui portent le nom de ce qu'on va y faire
-- =====================================================================
-- Les neuf tuiles de l'accueil sont les MODULES hérités de 6ammart : des
-- regroupements de commerçants, pas des intentions de client. Personne ne se
-- dit « je vais dans le module Kasuwa ».
--
-- Ce que les produits disent, une fois comptés :
--
--     1 275  Manger                    (Restaurants + Street-food)
--       315  Marché & courses
--       123  Beauté & soins
--       111  Téléphone & électronique
--        59  Vêtements
--        17  Pharmacie
--         7  Gaz
--         2  Billetterie
--
-- Cette migration fait les quatre corrections décidées, et rien de plus. La
-- refonte complète en activités attend une décision d'architecture qui la
-- dépasse — voir la note en fin de fichier.

-- ---------------------------------------------------------------------
-- 1. Kasuwa devient Marché
-- ---------------------------------------------------------------------
-- « Kasuwa » est le marché en haoussa, et c'est exactement l'usage : on y
-- envoie quelqu'un acheter de la viande crue, des œufs, des légumes au tas.
-- Les produits le confirment — Rognon de mouton, Gésier de poulet, Gombo,
-- Piment frais. Le nom local est juste ; il n'est simplement pas explicite
-- pour qui ouvre l'application sans savoir ce qu'il y trouvera.

update categories set name = 'Marché'
 where parent_id is null and name = 'Kasuwa';

-- « Kasuwa 1 » est le MÊME module, dupliqué : un seul commerçant, seize
-- produits, et trois sous-catégories aux noms identiques — Viande et
-- volailles, Fruits, Légumes. Le renommer laisserait « Marché » à côté de
-- « Kasuwa 1 », ce qui serait pire qu'avant. On le fusionne.
--
-- CE FONDU EST UN CHOIX QUE JE PRENDS, et il se défait : il suffit de
-- réactiver la racine et de rendre au commerçant son ancien module.
do $$
declare
  v_marche  uuid;
  v_doublon uuid;
begin
  select id into v_marche  from categories where parent_id is null and name = 'Marché';
  select id into v_doublon from categories where parent_id is null and name = 'Kasuwa 1';
  if v_marche is null or v_doublon is null then return; end if;

  -- Les produits rejoignent la sous-catégorie de MÊME NOM sous Marché.
  update products p
     set category_id = cible.id
    from categories source
    join categories cible
      on public.texte_reduit(cible.name) = public.texte_reduit(source.name)
     and cible.parent_id = v_marche
   where p.category_id = source.id
     and source.parent_id = v_doublon;

  -- Le commerçant change de module, sinon sa boutique n'apparaîtrait plus
  -- derrière aucune porte.
  update merchants set category_id = v_marche where category_id = v_doublon;

  -- La racine disparaît dans tous les cas : c'est une porte en double.
  update categories set is_active = false where id = v_doublon;

  -- Les sous-catégories, elles, seulement si elles sont VIDES. Une
  -- sous-catégorie sans équivalent sous Marché garderait ses produits ;
  -- la désactiver les rendrait introuvables au parcours, visibles
  -- seulement à la recherche — le pire des deux mondes, et silencieux.
  update categories c set is_active = false
   where c.parent_id = v_doublon
     and not exists (
       select 1 from products p
       where p.category_id = c.id and p.is_available
     );
end $$;

-- ---------------------------------------------------------------------
-- 2. Grocery devient Supermarché
-- ---------------------------------------------------------------------
-- Deux portes distinctes, et non une seule « courses ». Aller au marché et
-- aller au supermarché ne sont pas le même geste : l'un se négocie au tas,
-- l'autre se prend en rayon. Les produits le montrent — CELERI et RAS EL
-- HANOUT d'un côté, Panzani et Nescafé de l'autre.

update categories set name = 'Supermarché'
 where parent_id is null and name = 'Grocery';

-- ---------------------------------------------------------------------
-- 3. La billetterie disparaît de l'accueil
-- ---------------------------------------------------------------------
-- Sept commerçants y sont rattachés, pour DEUX billets disponibles. Une
-- tuile de la même taille que « Restaurants » et ses 1 275 produits promet
-- ce qui n'existe pas : on l'ouvre, on trouve deux lignes, on en conclut que
-- l'application est vide.
--
-- Masquée, pas supprimée. Le jour où la billetterie aura du contenu, une
-- ligne suffira à la faire revenir.

update categories set is_active = false
 where parent_id is null and name = 'Billetterie Evènements';

-- ---------------------------------------------------------------------
-- 4. Les treize produits sans catégorie
-- ---------------------------------------------------------------------
-- Ils n'étaient atteignables que par la recherche : invisibles à qui
-- parcourt le catalogue. Chacun rejoint une sous-catégorie que sa PROPRE
-- boutique utilise déjà, ou à défaut celle de son rayon.
--
-- La sous-catégorie est désignée par son nom ET son parent : « VIANDE ET
-- VOLAILLES » existe sous trois racines, « BEAUTE ET HYGIENE » sous deux.
-- Le nom seul ne désigne rien.

do $$
declare
  v_resto   uuid;
  v_super   uuid;
begin
  select id into v_resto from categories where parent_id is null and name = 'Restaurants';
  select id into v_super from categories where parent_id is null and name = 'Supermarché';

  -- Les manakish sont des pains garnis : leur boutique les range déjà dans
  -- SANDWICH, aux côtés de « Manakish Zaatar ».
  update products set category_id = (
    select id from categories where parent_id = v_resto and name = 'SANDWICH' limit 1
  ) where category_id is null and name ilike 'Manakish%';

  update products set category_id = (
    select id from categories where parent_id = v_resto and name = 'COCKTAILS' limit 1
  ) where category_id is null and name ilike '%COCKTAIL%';

  -- Maïs et petits pois en boîte.
  update products set category_id = (
    select id from categories where parent_id = v_super and name = 'CONSERVES' limit 1
  ) where category_id is null
    and (name ilike '%Maïs Sucré%' or name ilike '%Pois très fins%' or name ilike '%Compote%');

  update products set category_id = (
    select id from categories where parent_id = v_super
      and name = 'BISCUITS, BONBONS ET CHOCOLATS' limit 1
  ) where category_id is null and name ilike '%Chips%';

  -- Le miel et la poudre à pudding vont au rayon du sucre.
  update products set category_id = (
    select id from categories where parent_id = v_super
      and name = 'OEUFS, SUCRE ET FARINE' limit 1
  ) where category_id is null
    and (name ilike '%Miel%' or name ilike '%Pudding%');
end $$;

-- ---------------------------------------------------------------------
-- CE QUE CETTE MIGRATION NE FAIT PAS, ET POURQUOI
-- ---------------------------------------------------------------------
-- « Beauté », « Téléphone & électronique » et « Vêtements » ne peuvent pas
-- devenir des portes ici, et la raison est structurelle : LE PARCOURS PASSE
-- PAR LES BOUTIQUES. Une porte ouvre sur `category_merchants`, donc sur les
-- commerçants dont le `category_id` correspond — pas sur des produits.
--
-- Or les vingt-deux commerçants du module « Boutiques » vendent chacun
-- plusieurs de ces rayons à la fois : shampoing, manette de jeu et t-shirt
-- sous la même enseigne. Aucun découpage des commerçants ne produira ces
-- trois portes.
--
-- Le choix qui reste à faire dépasse une migration : garder le parcours par
-- boutique, qui est juste pour manger — on choisit un restaurant — ou
-- ouvrir un parcours par produit pour les marchandises, où l'enseigne
-- importe peu tant que le shampoing arrive.

notify pgrst, 'reload schema';
