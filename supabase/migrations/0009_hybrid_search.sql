-- =====================================================================
-- 0009 — Recherche hybride : vecteurs + lettres
-- =====================================================================
-- La recherche vectorielle comprend le SENS : « pâte de mil » retrouve
-- « tuo zaafi ». Mais aucun modèle d'embedding n'a beaucoup vu « tuo zaafi »,
-- « fura » ou « dèguè » à l'entraînement — ce sont des mots rares sur le web,
-- et leur représentation vectorielle est faible.
--
-- La recherche trigramme comprend les LETTRES : « tuo zafi », « tuozaafi »
-- ou « tuo zaaphi » retrouvent le bon produit malgré la faute. Elle ne
-- comprend rien au sens, mais elle est imbattable sur les noms propres et
-- les mots que le modèle ignore.
--
-- Les deux se complètent exactement là où l'autre échoue. On fusionne leurs
-- classements par Reciprocal Rank Fusion : chaque résultat marque
-- 1/(k + rang) dans chaque liste, et on additionne. Pas de seuil à régler,
-- pas d'échelles à harmoniser — un score de similarité cosinus et un score
-- trigramme ne sont pas comparables, leurs RANGS le sont.
-- =====================================================================

create extension if not exists pg_trgm;

-- Index trigramme sur le nom : c'est là que se joue la tolérance aux fautes.
create index if not exists idx_products_name_trgm
  on products using gin (name gin_trgm_ops);

create index if not exists idx_products_desc_trgm
  on products using gin (description gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Recherche hybride
-- ---------------------------------------------------------------------

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
  candidats as (
    select p.id, p.embedding, p.name, p.description
    from products p
    join merchants m on m.id = p.merchant_id
    cross join origine o
    cross join parametres pa
    where m.is_approved
      and p.is_available
      and (filter_category is null or p.category_id = filter_category)
      and (o.point is null or st_dwithin(m.location, o.point, pa.rayon))
  ),
  -- Classement sémantique.
  par_sens as (
    select c.id, row_number() over (order by c.embedding <=> query_embedding) as rang
    from candidats c
    where query_embedding is not null and c.embedding is not null
    limit 40
  ),
  -- Classement lexical, tolérant aux fautes.
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
  -- Reciprocal Rank Fusion. k = 60, valeur usuelle : elle amortit l'écart
  -- entre la première et la deuxième place, ce qui évite qu'une seule des
  -- deux recherches n'impose systématiquement son premier résultat.
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
  order by f.score desc, p.price asc
  limit (select n from parametres);
$$;

-- ---------------------------------------------------------------------
-- Indexation des produits
-- ---------------------------------------------------------------------
-- Marque les produits dont l'embedding est absent ou périmé, pour que le
-- backend sache lesquels réindexer. Un produit dont on change le nom ou la
-- description doit être réindexé, sinon la recherche continue de répondre
-- sur l'ancien texte.

alter table products
  add column if not exists embedded_at timestamptz,
  add column if not exists embedding_source text;

create index if not exists idx_products_a_indexer
  on products(updated_at)
  where embedding is null or embedded_at is null;

create or replace function public.products_to_embed(limite integer default 50)
returns table (
  id                uuid,
  name              text,
  description       text,
  image_description text,
  tags              text[]
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.description, p.image_description, p.tags
  from products p
  where p.embedding is null
     or p.embedded_at is null
     or p.embedded_at < p.updated_at
  order by p.updated_at desc
  limit limite;
$$;

notify pgrst, 'reload schema';
