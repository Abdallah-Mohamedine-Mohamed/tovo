-- =====================================================================
-- 0047 — Huit portes, chacune ouvrant sur ce qu'elle annonce
-- =====================================================================
-- Suite de 0046, qui avait renommé et masqué sans toucher à la structure.
-- Celle-ci dissout les modules qui ne correspondent à aucune intention, et
-- introduit la distinction qui manquait : selon la porte, on cherche une
-- BOUTIQUE ou un PRODUIT.
--
-- LE CRITÈRE N'EST PAS TECHNIQUE : l'enseigne compte-t-elle dans la
-- décision ?
--
--   Pour manger, oui. On choisit un restaurant parce qu'on fait confiance à
--   sa cuisine. Un « 1/2 poulet » sorti de son restaurant n'aide personne.
--
--   Pour une marchandise, non. Personne ne veut choisir l'enseigne avant le
--   shampoing. Laquelle des vingt-deux boutiques l'a en stock est un détail
--   d'exécution qu'on faisait porter au client.
--
-- CE QUE 0046 AVAIT LAISSÉ :
--
--   « Boutiques » — 22 commerçants vendant chacun plusieurs rayons. Aucun
--   découpage des COMMERÇANTS ne produisait « Beauté », « Téléphone » ou
--   « Vêtements » : il fallait passer par les produits.
--
--   « Tovo market » — quatre commerçants sans rapport : KASUWA vend de la
--   viande, BOUTEILLE DE GAZ des bouteilles, TOVO SHOP des pâtes, CHAISE ET
--   BACHE plus rien du tout. Un module qui ne veut rien dire.
--
--   « Street-food » — quatre restaurants. Poulet suya, sandwich à
--   l'omelette, jus de bissap. Une porte de plus pour la même intention.

alter table categories
  add column if not exists browse_mode text not null default 'merchants'
  check (browse_mode in ('merchants', 'products'));

comment on column categories.browse_mode is
  'Ce que la porte ouvre : « merchants » quand l''enseigne fait partie du choix (on choisit son restaurant), « products » quand elle n''y est pour rien (on veut le shampoing, pas la boutique).';

do $$
declare
  v_resto   uuid;
  v_marche  uuid;
  v_super   uuid;
  v_gaz     uuid;
  v_elec    uuid;
  v_beaute  uuid;
  v_vet     uuid;
  v_boutiq  uuid;
  v_tovom   uuid;
  v_street  uuid;
  v_cible   uuid;
begin
  select id into v_resto  from categories where parent_id is null and name = 'Restaurants';
  select id into v_marche from categories where parent_id is null and name = 'Marché';
  select id into v_super  from categories where parent_id is null and name = 'Supermarché';
  select id into v_gaz    from categories where parent_id is null and slug = 'gaz-m12';
  select id into v_boutiq from categories where parent_id is null and name = 'Boutiques';
  select id into v_tovom  from categories where parent_id is null and name = 'Tovo market';
  select id into v_street from categories where parent_id is null and name = 'Street-food';

  -- « Électronique » existe déjà, vide, avec un slug propre hérité d'un
  -- essai antérieur. La réutiliser vaut mieux qu'en créer une jumelle.
  select id into v_elec from categories where parent_id is null and slug = 'electronique';
  update categories set name = 'Électronique & téléphone', is_active = true where id = v_elec;

  insert into categories (name, slug, sort_order, is_active)
  select 'Beauté & soins', 'beaute-soins', 4, true
   where not exists (select 1 from categories where slug = 'beaute-soins');
  select id into v_beaute from categories where slug = 'beaute-soins';

  insert into categories (name, slug, sort_order, is_active)
  select 'Vêtements', 'vetements', 6, true
   where not exists (select 1 from categories where slug = 'vetements');
  select id into v_vet from categories where slug = 'vetements';

  -- SANS CE CONTRÔLE, une destination manquante ferait des dégâts muets :
  -- `set parent_id = v_beaute` avec v_beaute à NULL promeut les rayons de
  -- beauté au rang de RACINES, et ils apparaîtraient comme des portes à
  -- part entière sur l'accueil. Mieux vaut échouer bruyamment.
  if v_resto is null or v_marche is null or v_super is null
     or v_gaz is null or v_elec is null or v_beaute is null or v_vet is null then
    raise exception '0047 : destination manquante (resto=%, marche=%, super=%, gaz=%, elec=%, beaute=%, vet=%)',
      v_resto, v_marche, v_super, v_gaz, v_elec, v_beaute, v_vet;
  end if;

  -- -------------------------------------------------------------------
  -- « Boutiques » se répartit selon ce que ses rayons contiennent
  -- -------------------------------------------------------------------
  update categories set parent_id = v_beaute
   where parent_id = v_boutiq
     and name in ('Beauté et hygiène', 'SOINS DU CORPS', 'SOINS DE CHEVEUX',
                  'Parfum', 'COMPLEMENTS ALIMENTAIRES');

  update categories set parent_id = v_elec
   where parent_id = v_boutiq
     and name in ('JEUX VIDEO ET CONSOLES', 'ELECTRONIQUES', 'ELECTROMENAGER',
                  'ACCESSOIRES DE TELEPHONE', 'INFORMATIQUES', 'ACCESSOIRES AUTOMOBILE');

  update categories set parent_id = v_vet
   where parent_id = v_boutiq
     and name in ('T-SHIRT', 'CHEMISE', 'PULL-OVER', 'CHAUSSURES', 'Bijoux', 'Hood');

  -- Boissons en canette, chips, thé en sachet : c'est du rayon, pas de la
  -- boutique de mode.
  update categories set parent_id = v_super
   where parent_id = v_boutiq
     and name in ('BOISSONS NON GAZEUSE', 'BOISSONS GAZEUSE', 'BOISSONS ENERGISANTES',
                  'Snacks', 'Thé et Infusion', 'Produits surgelé');

  -- Pintade, casier d'œufs, toukoudi : ça se prend au marché.
  update categories set parent_id = v_marche
   where parent_id = v_boutiq and name = 'Produits locaux';

  -- -------------------------------------------------------------------
  -- « Tovo market » se dissout dans ses destinations
  -- -------------------------------------------------------------------
  update categories set parent_id = v_gaz
   where parent_id = v_tovom and name like '%GAZ%';

  update categories set parent_id = v_elec
   where parent_id = v_tovom and name = 'MULTIMEDIA';

  update categories set parent_id = v_super
   where parent_id = v_tovom and name = 'PRODUITS ALIMENTAIRES';

  -- L'« EPICERIE » de Tovo market, c'est de l'huile en bidon — pas les
  -- épices en vrac de celle du Marché. Ses produits rejoignent le rayon
  -- correspondant du supermarché, sans emporter la catégorie elle-même.
  -- La cible est lue AVANT : un sous-select vide écrirait NULL et rendrait
  -- ces produits orphelins, c'est-à-dire invisibles au parcours.
  select id into v_cible from categories
   where parent_id = v_super and name = 'HUILES, EPICES ET SAUCES' limit 1;
  if v_cible is not null then
    update products p set category_id = v_cible
     where p.category_id in (
       select id from categories where parent_id = v_tovom and name = 'EPICERIE'
     );
  end if;

  -- Viande, fruits et légumes existent déjà sous Marché : on fond les
  -- produits dans les rayons de même nom plutôt que de créer des doublons.
  update products p
     set category_id = cible.id
    from categories source
    join categories cible
      on public.texte_reduit(cible.name) = public.texte_reduit(source.name)
     and cible.parent_id = v_marche
   where p.category_id = source.id
     and source.parent_id = v_tovom;

  -- -------------------------------------------------------------------
  -- « Street-food » rejoint les restaurants
  -- -------------------------------------------------------------------
  -- « PLAT » au singulier chez l'un, « PLATS » chez l'autre : le nom
  -- normalisé ne suffit pas, ce cas se traite à la main.
  select id into v_cible from categories
   where parent_id = v_resto and name = 'PLATS' limit 1;
  if v_cible is not null then
    update products p set category_id = v_cible
     where p.category_id in (
       select id from categories where parent_id = v_street and name = 'PLAT'
     );
  end if;

  update products p
     set category_id = cible.id
    from categories source
    join categories cible
      on public.texte_reduit(cible.name) = public.texte_reduit(source.name)
     and cible.parent_id = v_resto
   where p.category_id = source.id
     and source.parent_id = v_street;

  -- -------------------------------------------------------------------
  -- Les commerçants suivent
  -- -------------------------------------------------------------------
  -- Sans ça, une boutique se retrouverait derrière une porte fermée : ses
  -- produits visibles, elle-même introuvable.
  update merchants set category_id = v_resto  where category_id = v_street;
  update merchants set category_id = v_marche where category_id = v_tovom and name = 'KASUWA';
  update merchants set category_id = v_gaz    where category_id = v_tovom and name = 'BOUTEILLE DE GAZ';
  update merchants set category_id = v_super  where category_id = v_tovom and name = 'TOVO SHOP';
  -- CHAISE ET BACHE n'a plus aucun produit disponible : elle reste où elle
  -- est, derrière une porte masquée, jusqu'à ce qu'elle regarnisse sa carte.

  -- Les vingt-deux commerçants de « Boutiques » ne bougent PAS. Leurs
  -- produits sont désormais atteints par rayon, sans passer par eux ; leur
  -- module ne sert plus de porte, il reste leur rattachement d'origine.

  -- -------------------------------------------------------------------
  -- Les portes dissoutes
  -- -------------------------------------------------------------------
  -- Masquées, jamais supprimées : un module effacé emporterait l'historique
  -- des commandes qui le référencent.
  update categories set is_active = false
   where id in (v_boutiq, v_tovom, v_street);

  -- Une sous-catégorie restée derrière une porte masquée n'est atteignable
  -- que par la recherche. On ne la désactive donc que si elle est vide.
  update categories c set is_active = false
   where c.parent_id in (v_boutiq, v_tovom, v_street)
     and not exists (
       select 1 from products p where p.category_id = c.id and p.is_available
     );

  -- -------------------------------------------------------------------
  -- Le mode, et l'ordre d'apparition
  -- -------------------------------------------------------------------
  update categories set browse_mode = 'products'
   where id in (v_beaute, v_elec, v_vet);

  update categories set sort_order = 1 where id = v_resto;
  update categories set sort_order = 2 where id = v_marche;
  update categories set sort_order = 3 where id = v_super;
  update categories set sort_order = 4 where id = v_beaute;
  update categories set sort_order = 5 where id = v_elec;
  update categories set sort_order = 6 where id = v_vet;
  update categories set sort_order = 7 where id = v_gaz;
  update categories set sort_order = 8
   where parent_id is null and slug = 'parapharmacies-m5';
end $$;

-- ---------------------------------------------------------------------
-- La porte doit dire son mode
-- ---------------------------------------------------------------------
-- Sans cette colonne dans le résultat, le backend devrait relire la
-- catégorie pour savoir quoi renvoyer — une requête de plus à chaque
-- ouverture d'écran.

-- AJOUTER UNE COLONNE AU RÉSULTAT CHANGE LE TYPE DE RETOUR, et PostgreSQL
-- refuse alors le remplacement : « cannot change return type of existing
-- function ». Il faut retirer l'ancienne d'abord — même contrainte qu'en
-- 0041, où c'était l'ajout d'un paramètre.
--
-- Sans argument, la signature est sans ambiguïté.
drop function if exists public.browsable_categories();

create function public.browsable_categories()
returns table (
  id          uuid,
  name        text,
  slug        text,
  icon        text,
  image_url   text,
  browse_mode text
)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.slug, c.icon, c.image_url, c.browse_mode
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
