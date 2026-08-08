-- =====================================================================
-- 0023 — La recherche tient compte des heures d'ouverture
-- =====================================================================
-- Dernier endroit où le défaut subsistait. Le panier le sait depuis la
-- 0021, les catégories depuis la 0022 ; `search_products` filtrait encore
-- sur `is_approved` et `is_available`, jamais sur l'ouverture.
--
-- Un client qui cherche des tacos à 8 h voyait donc les plats de
-- restaurants qui n'ouvrent qu'à 11 h, les ajoutait au panier, et
-- découvrait au moment de commander que personne ne prépare.
--
-- CE QU'ON NE FAIT PAS : masquer les boutiques fermées. À 8 h du matin,
-- presque tout est fermé à Niamey — la recherche ne renverrait rien du
-- tout, ce qui est pire que d'informer. Un client qui voit « ouvre à 11 h »
-- sait à quoi s'en tenir et reviendra ; un client qui lit « rien trouvé »
-- pense que Tovo est vide.
--
-- On classe donc les ouvertes d'abord, et on dit lesquelles le sont.

-- `create or replace` ne peut pas changer le type de retour : on ajoute une
-- colonne `merchant_open`, donc il faut supprimer avant de recréer. La
-- signature est reprise en entier, sans quoi Postgres ne saurait pas
-- laquelle viser s'il en existait plusieurs.
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
      coalesce(radius_m, (select search_radius_m from platform_settings), 5000) as rayon
  ),
  origine as (
    select case
      when origin_lat is null or origin_lng is null then null
      else st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography
    end as point
  ),
  -- Périmètre commun aux deux recherches : boutique approuvée, produit
  -- disponible, et dans le rayon si une position est fournie.
  --
  -- La catégorie accepte aussi bien une racine qu'une feuille : les produits
  -- pendent aux feuilles depuis la migration, chercher sur une racine ne
  -- ramenait rien.
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
      and (o.point is null or st_dwithin(m.location, o.point, pa.rayon))
  ),
  par_sens as (
    select c.id, row_number() over (order by c.embedding <=> query_embedding) as rang
    from candidats c
    where query_embedding is not null and c.embedding is not null
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
    p.id,
    p.merchant_id,
    m.name,
    public.merchant_open_now(m.id),
    p.name,
    p.description,
    p.image_url,
    p.price,
    p.is_available,
    case when o.point is null then null
         else st_distance(m.location, o.point)::integer end,
    f.score
  from fusion f
  join products p on p.id = f.id
  join merchants m on m.id = p.merchant_id
  cross join origine o
  cross join parametres pa
  -- Ouvertes d'abord, puis la pertinence. Un plat parfaitement trouvé mais
  -- incommandable vaut moins qu'un plat correct qu'on peut avoir tout de
  -- suite.
  order by public.merchant_open_now(m.id) desc, f.score desc, p.price asc
  limit (select n from parametres);
$$;

notify pgrst, 'reload schema';
