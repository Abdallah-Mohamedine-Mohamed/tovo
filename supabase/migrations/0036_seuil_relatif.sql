-- =====================================================================
-- 0036 — Un seuil qui s'adapte à la requête
-- =====================================================================
-- « écouteurs » ne rendait RIEN, alors que le catalogue contient des Apple
-- EarPods. « écouteurs sans fil » rendait une manette de PS5, parce que la
-- seule branche encore vivante était la branche lexicale, et qu'elle
-- accrochait « sans fil ».
--
-- La branche sémantique ne produisait plus rien du tout. MESURE, meilleur
-- score obtenu sur le catalogue réel :
--
--     jus de bissap                        0,885   (le nom exact du produit)
--     du poulet pas cher                   0,746
--     écouteurs                            0,673   (Apple EarPods)
--     écouteurs sans fil                   0,628   (Apple EarPods)
--     quelque chose de léger pour ce soir  0,580
--
-- Le seuil de 0,70 fixé en 0024 était calibré sur « jus de bissap » — une
-- requête qui reprend le nom du produit. Or c'est précisément le cas où le
-- sens ne sert à RIEN : le lexical suffit. Le seul cas où la sémantique est
-- utile, c'est quand le client emploie un autre mot que le boutiquier — et
-- ce cas-là notait toujours sous 0,70.
--
-- UN SEUIL ABSOLU NE PEUT PAS MARCHER, et les chiffres le montrent : le
-- 50e résultat de « jus de bissap » note 0,618, au-dessus du MEILLEUR
-- résultat de « écouteurs sans fil » à 0,628. Aucune valeur unique ne sépare
-- les deux. L'échelle dépend de la requête.
--
-- On garde donc un plancher, mais on y ajoute une marge RELATIVE au meilleur
-- score : un produit est retenu s'il est proche du meilleur trouvé. Une
-- requête précise se resserre d'elle-même — « jus de bissap » ne garde que
-- du bissap — tandis qu'une requête vague reste ouverte.
--
-- POURQUOI LE PLANCHER PEUT DESCENDRE À 0,62. En 0024, il devait aussi
-- écarter les phrases qui ne cherchent rien : « bonjour » notait 0,649,
-- « il est où le livreur » 0,613. Ces phrases n'atteignent plus la
-- recherche : l'application les reconnaît à leur forme et les envoie
-- directement à l'assistant. Le seuil n'a plus qu'un seul travail —
-- distinguer un produit trouvé d'un produit absent.

update platform_settings set search_min_similarity = 0.62;

comment on column platform_settings.search_min_similarity is
  'Plancher de pertinence sémantique. S''y ajoute une marge relative au meilleur résultat (voir search_products) : c''est elle qui resserre les requêtes précises. Monter ce plancher exclut les recherches par synonyme — « écouteurs » pour des AirPods note 0,673.';

alter table platform_settings
  add column if not exists search_relative_margin numeric(3,2) not null default 0.08;

comment on column platform_settings.search_relative_margin is
  'Écart maximal toléré sous le meilleur score sémantique. Réduire resserre les résultats autour du premier ; augmenter en fait remonter davantage.';

create or replace function public.search_products(
  query_text      text,
  query_embedding vector(1536) default null,
  origin_lat      double precision default null,
  origin_lng      double precision default null,
  radius_m        integer default null,
  filter_category uuid default null,
  match_count     integer default null
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
      coalesce((select search_relative_margin from platform_settings), 0.08) as marge
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
      and b.sim >= (select max(sim) from sens_bruts) - pa.marge
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
      coalesce(1.0 / (60 + s.rang), 0) + coalesce(1.0 / (60 + l.rang), 0) as score
    from par_sens s
    full outer join par_lettres l on l.id = s.id
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
