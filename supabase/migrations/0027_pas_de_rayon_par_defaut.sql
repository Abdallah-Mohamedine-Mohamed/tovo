-- =====================================================================
-- 0027 — Tout le catalogue, pas seulement le voisinage
-- =====================================================================
-- La recherche écartait toute boutique à plus de 5 km. Sur le papier c'est
-- raisonnable ; à l'usage c'est un piège.
--
-- Niamey fait une trentaine de kilomètres d'est en ouest. Un client de
-- Yantala ne voyait rien du Plateau, rien de Lazaret, rien de Talladjé. Il
-- concluait que Tovo n'avait presque rien — alors que les trois quarts du
-- catalogue étaient là, à quinze minutes de moto.
--
-- La distance reste utile, mais pour CLASSER, pas pour exclure. Une boutique
-- proche remonte devant une boutique lointaine ; aucune ne disparaît.
--
-- Le rayon reste disponible quand l'appelant en demande un explicitement —
-- le dispatch des livreurs en a besoin, et lui a ses propres réglages.

-- 0 signifie désormais « pas de limite ». La colonne reste, pour le jour où
-- Tovo livrera dans plusieurs villes et où montrer Zinder à un client de
-- Niamey n'aurait plus de sens.
alter table platform_settings
  alter column search_radius_m set default 0;

update platform_settings set search_radius_m = 0;

comment on column platform_settings.search_radius_m is
  'Rayon de recherche en mètres. 0 = tout le catalogue, quelle que soit la distance. La distance sert alors uniquement au classement.';

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
      -- 0 ou null : aucune limite de distance.
      nullif(coalesce(radius_m, (select search_radius_m from platform_settings), 0), 0) as rayon,
      coalesce((select search_min_similarity from platform_settings), 0.70) as seuil
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
  par_sens as (
    select c.id, row_number() over (order by c.embedding <=> query_embedding) as rang
    from candidats c, parametres pa
    where query_embedding is not null
      and c.embedding is not null
      and 1 - (c.embedding <=> query_embedding) >= pa.seuil
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
  order by public.merchant_open_now(m.id) desc, f.score desc, p.price asc
  limit (select n from parametres);
$$;

/*
 * Les boutiques d'une catégorie : toutes, quelle que soit la distance.
 *
 * Même raison. La position, quand elle est connue, sert à mettre les plus
 * proches devant — jamais à faire disparaître les autres.
 */
create or replace function public.category_merchants(
  p_category_id uuid,
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_limite      integer default 50
)
returns table (
  id            uuid,
  name          text,
  description   text,
  logo_url      text,
  address_hint  text,
  is_open       boolean,
  rating        numeric,
  prep_time_min integer,
  distance_m    integer
)
language sql stable security definer set search_path = public as $$
  with origine as (
    select case
      when p_lat is null or p_lng is null then null
      else st_setsrid(st_point(p_lng, p_lat), 4326)::geography
    end as point
  )
  select
    m.id, m.name, m.description, m.logo_url, m.address_hint,
    public.merchant_open_now(m.id),
    m.rating, m.prep_time_min,
    case when o.point is null then null
         else st_distance(m.location, o.point)::integer end
  from merchants m
  cross join origine o
  where m.is_approved
    and m.category_id = p_category_id
  order by
    public.merchant_open_now(m.id) desc,
    case when o.point is null then m.rating * -1
         else st_distance(m.location, o.point) end,
    m.name
  limit p_limite
$$;

notify pgrst, 'reload schema';
