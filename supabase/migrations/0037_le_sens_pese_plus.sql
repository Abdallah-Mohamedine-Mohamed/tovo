-- =====================================================================
-- 0037 — Le sens pèse plus que les lettres
-- =====================================================================
-- « écouteurs sans fil » rendait une MANETTE DE PS5 en premier, devant les
-- AirPods.
--
-- Le seuil relatif de 0036 avait pourtant fait son travail : la branche
-- sémantique classait bien les AirPods premiers. Mais la branche lexicale
-- classait la manette première, parce qu'elle partage « sans fil » avec la
-- requête — deux mots génériques, présents dans des centaines de produits.
--
-- Les deux premières places valaient donc exactement 1/61 chacune. À score
-- égal, le classement final départage par le PRIX LE PLUS BAS : la manette
-- à 18 000 passait devant les AirPods à 45 000. Un détail de tri décidait
-- de la pertinence.
--
-- LA VRAIE QUESTION n'est pas comment départager, mais pourquoi ces deux
-- signaux valent le même poids. Ils ne se valent pas :
--
--   La branche sémantique est filtrée deux fois — un plancher absolu ET une
--   marge relative au meilleur score. Ce qui en sort a passé un examen.
--
--   La branche lexicale n'a aucun filtre équivalent. Elle compare des
--   suites de trois lettres, et un modificateur banal comme « sans fil »
--   suffit à la satisfaire. Elle ignore quel mot porte le sens : ici
--   « écouteurs », que la manette ne contient nulle part.
--
-- On lui donne donc un poids légèrement moindre. 0,85 défait l'égalité — la
-- manette tombe à 0,0139 contre 0,0164 aux AirPods — sans rien changer aux
-- cas où les deux branches s'accordent : un produit trouvé par les deux
-- cumule les deux scores et reste loin devant.
--
-- Réglable, parce que c'est un arbitrage et non une constante physique.

alter table platform_settings
  add column if not exists search_lexical_weight numeric(3,2) not null default 0.85;

comment on column platform_settings.search_lexical_weight is
  'Poids de la correspondance par les lettres face à celle par le sens. Sous 1, le sens prime — c''est ce qui empêche un modificateur banal (« sans fil ») de faire remonter un produit sans rapport. À 1, les deux signaux valent autant.';

notify pgrst, 'reload schema';
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
      coalesce((select search_relative_margin from platform_settings), 0.08) as marge,
      coalesce((select search_lexical_weight from platform_settings), 0.85) as poids_lettres
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
