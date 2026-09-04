-- =====================================================================
-- 0048 — Deux produits retenus par des rayons masqués
-- =====================================================================
-- Après 0047, quatre produits disponibles n'étaient plus atteignables en
-- parcourant le catalogue. Deux sont voulus — les billets, dont la porte est
-- masquée exprès. Les deux autres ne le sont pas :
--
--     Casque P9    dans un « ACCESSOIRES DE TELEPHONE » masqué,
--                  alors qu'un autre du même nom, actif, en contient 14.
--     PULL-OVER    dans un rayon nommé « Hood », masqué,
--                  alors qu'un rayon « PULL-OVER » actif en contient 4.
--
-- CES DOUBLONS SONT ANTÉRIEURS. 0047 les a déplacés sous leur nouvelle
-- racine sans les créer ni les réparer : un rayon masqué reste masqué où
-- qu'on le range. Le produit, lui, restait visible à la recherche et
-- introuvable au parcours — le silence habituel.

do $$
declare
  v_actif  uuid;
  v_masque uuid;
begin
  -- Les accessoires de téléphone, en double sous la même racine.
  select id into v_actif  from categories
   where name = 'ACCESSOIRES DE TELEPHONE' and is_active order by id limit 1;
  select id into v_masque from categories
   where name = 'ACCESSOIRES DE TELEPHONE' and not is_active order by id limit 1;

  if v_actif is not null and v_masque is not null then
    update products set category_id = v_actif where category_id = v_masque;
  end if;

  -- « Hood » n'est pas un rayon, c'est une étiquette laissée par la
  -- migration d'origine : elle contient un pull-over, et rien d'autre.
  select id into v_actif  from categories where name = 'PULL-OVER' and is_active limit 1;
  select id into v_masque from categories where name = 'Hood' limit 1;

  if v_actif is not null and v_masque is not null then
    update products set category_id = v_actif where category_id = v_masque;
    update categories set is_active = false where id = v_masque;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- La beauté ne doit pas être coupée en deux
-- ---------------------------------------------------------------------
-- Deux rayons portent le même nom sous deux portes différentes :
--
--     « Beauté et hygiène »   65 produits, sous Beauté & soins
--     « BEAUTE ET HYGIENE »   25 produits, sous Supermarché
--
-- Le second vient du module Grocery : déodorants Rexona, savons. Le premier
-- vient des boutiques : cosmétiques, shampoings. La distinction a un sens
-- pour le grossiste, aucun pour le client — qui cherche un déodorant sous
-- « Beauté », ne l'y trouve pas, et conclut que Tovo n'en vend pas.
--
-- UNE PORTE PORTE LE NOM DE CE QU'ON VEUT, pas de l'enseigne qui le stocke.
-- Ces 25 produits rejoignent donc la beauté. Ils ne disparaissent pas du
-- supermarché pour autant : parcourir une boutique montre TOUTE sa carte,
-- quelle que soit la catégorie de chaque article.

do $$
declare
  v_beaute uuid;
  v_source uuid;
begin
  select id into v_beaute from categories where slug = 'beaute-soins';
  select c.id into v_source
    from categories c
    join categories r on r.id = c.parent_id
   where c.name = 'BEAUTE ET HYGIENE' and r.name = 'Supermarché'
   limit 1;

  if v_beaute is not null and v_source is not null then
    update categories set parent_id = v_beaute where id = v_source;
  end if;
end $$;

notify pgrst, 'reload schema';
