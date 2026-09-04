-- =====================================================================
-- 0043 — Départager les produits qui offrent la même option
-- =====================================================================
-- La branche options de 0042 place le bon produit devant… quand elle veut.
-- Observé sur deux formulations de la même demande :
--
--     « tacos boulette »       -> Tacos M sort 4e
--     « tacos aux boulettes »  -> Tacos M ne sort pas du tout
--
-- Les mots retenus sont pourtant identiques dans les deux cas — « taco » et
-- « boulette », « aux » étant trop court. Le résultat ne devrait pas
-- changer.
--
-- LA CAUSE. Le classement se faisait sur le seul nombre de mots trouvés :
--
--     row_number() over (order by t.touches desc)
--
-- Des dizaines de produits proposent la boulette, tous avec le même nombre
-- de mots trouvés. `row_number` doit bien leur donner un rang, alors il en
-- invente un — celui que le plan d'exécution lui présente. Deux requêtes
-- voisines donnent deux plans voisins, donc deux ordres différents, et un
-- produit passe du quatrième rang à nulle part.
--
-- CE QUI MANQUAIT : un second critère qui ait un sens. Parmi les produits
-- qui offrent ce que le client demande en option, celui dont le NOM
-- correspond au reste de la demande est le plus pertinent. Pour « tacos aux
-- boulettes », un Tacos passe devant une pizza qui propose aussi la
-- boulette.
--
-- Et un troisième, purement technique : l'identifiant. Sans lui, deux appels
-- identiques peuvent rendre deux ordres différents — un défaut observé
-- devient alors impossible à reproduire, ce qui est la pire des situations.
--
-- LE `LIMIT` PASSE APRÈS LE CLASSEMENT. `limit 40` sans `order by` prélève
-- quarante lignes au hasard : le rang était calculé sur toutes, puis on en
-- gardait quarante quelconques. En pratique PostgreSQL rendait souvent les
-- mieux classées, mais rien ne l'y obligeait. Les deux autres branches n'ont
-- pas ce défaut : elles classent sur une valeur qui discrimine, et leurs
-- égalités sont rares.

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
      row_number() over (
        order by
          -- 1. Le nombre de mots trouvés. Deux options qui répondent valent
          --    mieux qu'une.
          t.touches desc,
          -- 2. À égalité, LE NOM. C'est ce qui manquait : des dizaines de
          --    produits proposent la boulette, et rien ne les départageait,
          --    donc l'ordre était arbitraire. Pour « tacos aux boulettes »,
          --    un Tacos passe devant une pizza qui l'offre aussi.
          similarity(c.name, query_text) desc,
          -- 3. Un départage stable. Sans lui, deux appels identiques
          --    peuvent rendre deux ordres différents, et un défaut observé
          --    devient impossible à reproduire.
          c.id
      ) as rang
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
    order by rang
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
