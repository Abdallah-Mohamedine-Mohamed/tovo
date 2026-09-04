-- =====================================================================
-- 0041 — « chez otakoss » doit vouloir dire quelque chose
-- =====================================================================
-- Vu en conversation. Le client écrit « Tacos aux boulettes de viande de
-- chez otakoss ». L'assistant répond :
--
--   « Des tacos chez O'Takoss, j'en ai trouvé plusieurs formats (M, L, XL,
--     XXL). Pour savoir quelle boutique est la plus près de chez vous […],
--     où est-ce qu'on se pose ? »
--
-- et affiche des tacos d'Albek Food, de ROYAL GRILL et de FESTIVAL DES
-- GLACES. Le client insiste : « otakoss j'ai dit ».
--
-- LA QUESTION SUR LA POSITION N'ÉTAIT PAS UN CAPRICE DU MODÈLE. Pour
-- retrouver O'TAKOSS il ne disposait que de `boutiques_proches`, qui cherche
-- par la GÉOGRAPHIE. Aucun outil ne permettait de trouver une boutique par
-- son nom. Il a donc demandé où se trouvait le client pour pouvoir chercher
-- une boutique que le client venait de nommer.
--
-- Et `search_products` ne savait pas restreindre à une boutique : elle
-- filtrait par catégorie, jamais par commerce. La contrainte la plus
-- naturelle qu'un client puisse poser — « chez untel » — n'existait pas.
--
-- Le paramètre s'ajoute EN FIN de signature, comme pour 0033. Mais ici un
-- `create or replace` ne suffit pas : en PostgreSQL, ajouter un paramètre
-- crée une SURCHARGE au lieu de remplacer, et PostgREST se retrouverait
-- devant deux fonctions de même nom sans savoir laquelle appeler. On retire
-- donc explicitement l'ancienne signature.
--
-- UN TABLEAU, ET NON UN IDENTIFIANT. « chez otakoss » désigne l'enseigne, et
-- O'TAKOSS a deux adresses au catalogue. En retenir une seule au hasard
-- masquerait la moitié de sa carte sans que rien ne le signale.

drop function if exists public.search_products(
  text, vector, double precision, double precision, integer, uuid, integer
);

create function public.search_products(
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
    select p.id, p.embedding, p.name, p.description
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
  fusion as (
    select
      coalesce(s.id, l.id) as id,
      coalesce(1.0 / (60 + s.rang), 0)
        + coalesce(pa.poids_lettres / (60 + l.rang), 0) as score
    from par_sens s
    full outer join par_lettres l on l.id = s.id
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
