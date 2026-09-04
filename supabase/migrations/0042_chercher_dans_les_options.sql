-- =====================================================================
-- 0042 — « tacos aux boulettes » : la boulette est une option
-- =====================================================================
-- Le client demande « Tacos aux boulettes de viande de chez otakoss ». La
-- boulette n'est pas un produit : c'est une valeur d'option à +600 F sur le
-- Tacos XL. La recherche ne regardait que le nom et la description, donc
-- elle ne pouvait pas le savoir.
--
-- 584 produits ont des options — 28 % du catalogue. Autant de « viande
-- hachée », « merguez », « pâte noire », « sans piment » invisibles.
--
-- CE QU'IL NE FALLAIT PAS FAIRE : ajouter les options au texte vectorisé.
-- C'était mon idée de départ ; mesurée, elle DÉGRADE tout, y compris la
-- requête qu'elle devait servir :
--
--     requête                          sans     avec
--     tacos aux boulettes de viande    0,617    0,534
--     tacos boulette                   0,676    0,625
--     tacos                            0,753    0,675
--     tacos XL                         0,671    0,541
--
-- Un embedding moyenne son texte. Deux cents caractères de noms de sauces
-- noient le signal « tacos » : le vecteur dérive vers un sens générique de
-- « liste de garnitures ». Plus on en dit, moins on ressemble.
--
-- CE QU'ON FAIT À LA PLACE. Une troisième branche, purement LEXICALE. Le mot
-- « boulette » est écrit tel quel dans l'option ; il suffit de le chercher
-- là où il est. Le vecteur reste intact, et ça ne coûte aucun appel d'API.
--
-- Poids volontairement faible : qu'un produit PUISSE recevoir de la boulette
-- est une information plus ténue que d'en porter le nom. Un « Tacos
-- Boulette » nommé ainsi doit rester devant un « Tacos XL » qui l'offre en
-- option.

-- ---------------------------------------------------------------------
-- Comparer des mots écrits par des humains
-- ---------------------------------------------------------------------
-- « Viande Hachée » doit se retrouver depuis « viande hachee », et
-- « boulettes » au pluriel depuis une option nommée « Boulette ». On réduit
-- donc les deux côtés à une forme commune : minuscules, sans accents, sans
-- le « s » final.
--
-- `translate` plutôt que l'extension `unaccent` : une dépendance de moins,
-- et les accents du français tiennent en une ligne.

create or replace function public.texte_reduit(entree text)
returns text language sql immutable strict parallel safe as $$
  select translate(
    lower(entree),
    'àâäéèêëîïôöùûüÿçÀÂÄÉÈÊËÎÏÔÖÙÛÜŸÇ',
    'aaaeeeeiioouuuycaaaeeeeiioouuuyc'
  );
$$;

comment on function public.texte_reduit(text) is
  'Minuscules et sans accents, pour comparer ce que des humains ont écrit — « Viande Hachée » et « viande hachee » doivent se rencontrer.';

-- ---------------------------------------------------------------------
-- Le texte des options, recopié sur le produit
-- ---------------------------------------------------------------------
-- Dénormalisé volontairement. La recherche filtre déjà sur deux jointures ;
-- en ajouter deux autres pour chaque produit candidat coûterait plus cher
-- que de maintenir cette colonne, qui ne change qu'à la modification d'une
-- carte.

alter table products
  add column if not exists options_text text;

comment on column products.options_text is
  'Noms des groupes d''options et de leurs valeurs, concaténés. Maintenu par trigger. Sert la branche lexicale de search_products : « boulette » est une option du Tacos XL, pas un produit.';

create or replace function public.calculer_options_text(p_product uuid)
returns text language sql stable set search_path = public as $$
  select nullif(string_agg(distinct t, ' '), '')
  from (
    select o.name as t from product_options o where o.product_id = p_product
    union all
    select v.name
    from product_options o
    join product_option_values v on v.option_id = o.id
    where o.product_id = p_product
      and v.is_available
  ) x;
$$;

create or replace function public.maj_options_text()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_product uuid;
begin
  -- Le produit concerné se trouve d'un côté ou de l'autre selon la table et
  -- selon qu'on insère ou qu'on supprime.
  if tg_table_name = 'product_options' then
    v_product := coalesce(new.product_id, old.product_id);
  else
    select o.product_id into v_product
    from product_options o
    where o.id = coalesce(new.option_id, old.option_id);
  end if;

  if v_product is not null then
    update products
       set options_text = public.calculer_options_text(v_product)
     where id = v_product;
  end if;

  return null;
end; $$;

drop trigger if exists options_text_sur_groupes on product_options;
create trigger options_text_sur_groupes
  after insert or update or delete on product_options
  for each row execute function public.maj_options_text();

drop trigger if exists options_text_sur_valeurs on product_option_values;
create trigger options_text_sur_valeurs
  after insert or update or delete on product_option_values
  for each row execute function public.maj_options_text();

-- Rattrapage des 584 produits existants. Pur SQL : aucun appel d'API, donc
-- instantané et gratuit, contrairement au rattrapage des images.
update products p
   set options_text = public.calculer_options_text(p.id)
 where exists (select 1 from product_options o where o.product_id = p.id);

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- La recherche regarde aussi les options
-- ---------------------------------------------------------------------

alter table platform_settings
  add column if not exists search_options_weight numeric(3,2) not null default 0.45;

comment on column platform_settings.search_options_weight is
  'Poids d''une correspondance trouvée dans les OPTIONS, face au nom (1,00) et au texte (0,85). Volontairement bas : qu''un produit puisse recevoir de la boulette est plus ténu que d''en porter le nom.';

create or replace function public.search_products(
  query_text      text,
  query_embedding vector(1536) default null,
  origin_lat      double precision default null,
  origin_lng      double precision default null,
  radius_m        integer default null,
  filter_category uuid default null,
  match_count     integer default null,
  filter_merchants uuid[] default null
)
returns table (
  id            uuid,
  merchant_id   uuid,
  merchant_name text,
  merchant_open boolean,
  name          text,
  description   text,
  image_url     text,
  price         integer,
  is_available  boolean,
  distance_m    integer,
  score         double precision
)
language sql stable security invoker set search_path = public as $$
  with parametres as (
    select
      coalesce(match_count, (select search_result_limit from platform_settings), 8) as n,
      -- 0 ou null : aucune limite de distance.
      nullif(coalesce(radius_m, (select search_radius_m from platform_settings), 0), 0) as rayon,
      case
        when coalesce(length(btrim(query_text)), 0) = 0 and query_embedding is not null
          then coalesce((select search_min_similarity_image from platform_settings), 0.38)
        else coalesce((select search_min_similarity from platform_settings), 0.62)
      end as seuil,
      coalesce((select search_relative_margin from platform_settings), 0.08) as marge,
      coalesce((select search_lexical_weight from platform_settings), 0.85) as poids_lettres,
      coalesce((select search_options_weight from platform_settings), 0.45) as poids_options,
      coalesce((select search_confidence_level from platform_settings), 0.75) as confiance,
      coalesce((select search_relative_margin_weak from platform_settings), 0.015) as marge_faible,
      (coalesce(length(btrim(query_text)), 0) = 0 and query_embedding is not null) as est_image
  ),
  origine as (
    select case
      when origin_lat is null or origin_lng is null then null
      else st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography
    end as point
  ),
  candidats as (
    select p.id, p.embedding, p.name, p.description, p.options_text
    from products p
    join merchants m on m.id = p.merchant_id
    left join categories enfant on enfant.id = p.category_id
    cross join origine o
    cross join parametres pa
    where m.is_approved
      and p.is_available
      and (
        filter_category is null
        or p.category_id = filter_category
        or enfant.parent_id = filter_category
      )
      -- Une boutique nommee restreint tout : le client qui dit « chez
      -- otakoss » ne veut pas voir les tacos du voisin.
      and (filter_merchants is null or p.merchant_id = any(filter_merchants))
      -- Le rayon ne s'applique que s'il a été demandé.
      and (pa.rayon is null or o.point is null or st_dwithin(m.location, o.point, pa.rayon))
  ),
  -- Les plus proches d'abord, SANS filtrer : on a besoin du meilleur score
  -- avant de pouvoir décider ce qui en est assez près.
  sens_bruts as (
    select c.id, 1 - (c.embedding <=> query_embedding) as sim
    from candidats c
    where query_embedding is not null
      and c.embedding is not null
    order by c.embedding <=> query_embedding
    limit 60
  ),
  par_sens as (
    select b.id, row_number() over (order by b.sim desc) as rang
    from sens_bruts b, parametres pa
    -- Deux conditions, et il faut les deux. Le plancher permet de ne RIEN
    -- trouver quand la requête ne correspond à aucun produit. La marge
    -- écarte la longue traîne d'une requête qui, elle, a bien trouvé.
    where b.sim >= pa.seuil
      and b.sim >= (select max(sim) from sens_bruts)
                   - case
                       -- La photo garde la marge large : ses scores vivent
                       -- entre 0,32 et 0,49 : le niveau de confiance des
                       -- mots n'y signifie rien, et la marge serrée ne
                       -- laisserait rien passer du tout.
                       when pa.est_image then pa.marge
                       when (select max(sim) from sens_bruts) >= pa.confiance
                         then pa.marge
                       else pa.marge_faible
                     end
    limit 40
  ),
  par_lettres as (
    select
      c.id,
      row_number() over (
        order by greatest(
          similarity(c.name, query_text),
          similarity(coalesce(c.description, ''), query_text) * 0.6
        ) desc
      ) as rang
    from candidats c
    where query_text is not null
      and length(trim(query_text)) > 1
      and (c.name % query_text or coalesce(c.description, '') % query_text)
    limit 40
  ),
  -- Troisième branche : les OPTIONS.
  --
  -- Mot à mot, et non par similarité de trigrammes sur la chaîne entière :
  -- « boulette » perdu dans deux cents caractères de sauces donne une
  -- similarité minuscule, alors que le mot y est écrit tel quel.
  --
  -- Le « s » final tombe des deux côtés — le client écrit « boulettes », le
  -- boutiquier a saisi « Boulette ». Les mots de moins de quatre lettres
  -- sont ignorés : « de », « au », « les » se retrouveraient partout.
  par_options as (
    select
      c.id,
      row_number() over (order by t.touches desc) as rang
    from candidats c
    cross join lateral (
      select count(distinct mot) as touches
      from unnest(regexp_split_to_array(public.texte_reduit(btrim(query_text)), '[^a-z0-9]+')) mot
      -- Quatre lettres APRÈS avoir retiré le pluriel : « sans » devient
      -- « san », trop court et trop commun pour signifier quoi que ce soit.
      where length(regexp_replace(mot, 's$', '')) >= 4
        and exists (
          select 1
          from unnest(regexp_split_to_array(
                 public.texte_reduit(c.options_text), '[^a-z0-9]+')) om
          -- MOT ENTIER, et non sous-chaîne. Mesuré : avec un simple LIKE,
          -- « san » attrapait « sandwich » et « pate » attrapait « patate »,
          -- ce qui donnait 187 produits pour « boisson sans sucre ».
          where regexp_replace(om, 's$', '')
              = regexp_replace(mot, 's$', '')
        )
    ) t
    where query_text is not null
      and c.options_text is not null
      and t.touches > 0
    limit 40
  ),
  fusion as (
    select
      ids.id,
      coalesce(1.0 / (60 + s.rang), 0)
        + coalesce(pa.poids_lettres / (60 + l.rang), 0)
        + coalesce(pa.poids_options / (60 + o.rang), 0) as score
    from (
      select id from par_sens
      union
      select id from par_lettres
      union
      select id from par_options
    ) ids
    left join par_sens    s on s.id = ids.id
    left join par_lettres l on l.id = ids.id
    left join par_options o on o.id = ids.id
    cross join parametres pa
  )
  select
    p.id, p.merchant_id, m.name,
    public.merchant_open_now(m.id),
    p.name, p.description, p.image_url, p.price, p.is_available,
    case when o.point is null then null
         else st_distance(m.location, o.point)::integer end,
    f.score
  from fusion f
  join products p on p.id = f.id
  join merchants m on m.id = p.merchant_id
  cross join origine o
  -- Ouvertes d'abord, puis la pertinence. Un plat parfaitement trouvé mais
  -- incommandable vaut moins qu'un plat correct qu'on peut avoir tout de
  -- suite.
  order by public.merchant_open_now(m.id) desc, f.score desc, p.price asc
  limit (select n from parametres);
$$;

notify pgrst, 'reload schema';
