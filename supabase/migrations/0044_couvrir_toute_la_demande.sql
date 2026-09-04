-- =====================================================================
-- 0044 — Le produit qui répond à TOUTE la demande
-- =====================================================================
-- « tacos boulettes » remontait « Tacos Poulet » et « Tacos au poulet »,
-- devant les tacos d'O'TAKOSS qui sont les seuls à proposer réellement la
-- boulette. Le client l'a dit sans détour : « ça fait erreur de m'amener du
-- tacos poulet à la place de boulettes ».
--
-- LE DIAGNOSTIC EST NET, parce que la même requête sans la branche
-- sémantique donnait la bonne réponse :
--
--     avec vecteur   Tacos Poulet (FESTIVAL) | Tacos au poulet (Albek)
--     texte seul     Tacos bowl (O'TAKOSS)   | Tacos Bowl (O'TAKOSS)
--
-- Pour un modèle d'embedding, un tacos à la viande ressemble à un tacos à la
-- viande — la ressemblance est réelle, la réponse est fausse. La branche
-- sémantique classait « Tacos Poulet » premier et noyait le signal exact que
-- la branche options avait pourtant trouvé.
--
-- CE QUI MANQUAIT. Les trois branches jugent chacune un aspect isolément :
-- le sens, les lettres du nom, les options. Aucune ne répond à la question
-- qui compte — CE PRODUIT SATISFAIT-IL TOUT CE QUI A ÉTÉ DEMANDÉ ?
--
-- « Tacos bowl » couvre les deux mots : « taco » par son nom, « boulette »
-- par ses options. « Tacos Poulet » n'en couvre qu'un.
--
-- VÉRIFIÉ SUR UNE RÉPLIQUE HORS-LIGNE du classement, validée au préalable
-- contre la base — elle reproduisait bien le défaut avant de servir à
-- choisir le remède :
--
--     requête               sans couverture          avec couverture
--     tacos boulettes       Tacos Poulet             Tacos bowl, Tacos Bowl
--     tacos poulet          tacos uniquement         inchangé
--     écouteurs sans fil    AirPods                  inchangé
--     jus de bissap         Jus de Bissap            inchangé
--     pizza thon            Pizza Thon               inchangé
--
-- Un seul cas change, et c'est celui qu'on visait.
--
-- POIDS 1,00, autant que le sens. Cela peut surprendre pour une branche
-- purement lexicale, mais elle exige DEUX mots couverts au minimum : sur une
-- demande d'un seul mot elle ne se déclenche pas, et ne prouverait rien de
-- plus que la branche lexicale. Rare et exigeante, donc digne de confiance
-- quand elle parle.

alter table platform_settings
  add column if not exists search_coverage_weight numeric(3,2) not null default 1.00;

comment on column platform_settings.search_coverage_weight is
  'Poids accordé à un produit qui couvre AU MOINS DEUX mots de la demande, nom et options confondus. C''est le signal le plus fort dont dispose la recherche : il dit que le produit répond à toute la demande, pas seulement à une partie.';

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
      coalesce((select search_coverage_weight from platform_settings), 1.00) as poids_couverture,
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
  -- Quatrième branche : la COUVERTURE de la demande.
  --
  -- Les trois autres jugent chacune un aspect isolément. Aucune ne répond à
  -- la question qui compte : ce produit satisfait-il TOUT ce qui a été
  -- demandé ?
  --
  -- Mesuré sur « tacos boulettes » : la branche sémantique plaçait « Tacos
  -- Poulet » en tête, parce qu'un tacos à la viande ressemble à un tacos à
  -- la viande. Elle noyait les tacos d'O'TAKOSS, qui sont les seuls à
  -- proposer réellement la boulette.
  --
  -- Ici, « Tacos bowl » couvre les deux mots — « taco » par son nom,
  -- « boulette » par ses options — quand « Tacos Poulet » n'en couvre qu'un.
  --
  -- DEUX MOTS AU MINIMUM : sur une demande d'un seul mot, couvrir « tout »
  -- ne prouve rien de plus que la branche lexicale. Cette exigence rend la
  -- branche rare et précise, ce qui justifie son poids élevé.
  par_couverture as (
    select
      c.id,
      row_number() over (
        order by t.couverts desc, similarity(c.name, query_text) desc, c.id
      ) as rang
    from candidats c
    cross join lateral (
      select count(distinct mot) as couverts
      from unnest(regexp_split_to_array(
             public.texte_reduit(btrim(query_text)), '[^a-z0-9]+')) mot
      where length(regexp_replace(mot, 's$', '')) >= 4
        and exists (
          select 1
          from unnest(regexp_split_to_array(
                 public.texte_reduit(c.name || ' ' || coalesce(c.options_text, '')),
                 '[^a-z0-9]+')) om
          where regexp_replace(om, 's$', '')
              = regexp_replace(mot, 's$', '')
        )
    ) t
    where query_text is not null
      and t.couverts >= 2
    order by rang
    limit 40
  ),
  fusion as (
    select
      ids.id,
      coalesce(1.0 / (60 + s.rang), 0)
        + coalesce(pa.poids_lettres / (60 + l.rang), 0)
        + coalesce(pa.poids_options / (60 + o.rang), 0)
        + coalesce(pa.poids_couverture / (60 + k.rang), 0) as score
    from (
      select id from par_sens
      union
      select id from par_lettres
      union
      select id from par_options
      union
      select id from par_couverture
    ) ids
    left join par_sens       s on s.id = ids.id
    left join par_lettres    l on l.id = ids.id
    left join par_options    o on o.id = ids.id
    left join par_couverture k on k.id = ids.id
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
