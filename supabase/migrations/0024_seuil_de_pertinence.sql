-- =====================================================================
-- 0024 — La recherche doit pouvoir ne rien trouver
-- =====================================================================
-- `search_products` n'avait AUCUN seuil de pertinence : sa moitié
-- vectorielle classait par distance et rendait les huit plus proches, quelle
-- que soit la requête. Chercher « xyzabc » renvoyait huit produits au hasard.
--
-- Le défaut restait invisible tant que la recherche passait par l'assistant :
-- le modèle recevait des résultats absurdes et reformulait poliment. Il est
-- devenu criant le jour où l'application a interrogé la recherche
-- directement — « annuler ma commande » remontait huit plats, et l'assistant
-- n'était jamais appelé.
--
-- LE SEUIL VIENT DE LA MESURE, pas d'une intuition. Similarité du meilleur
-- produit pour chaque requête, sur le catalogue réel :
--
--     jus de bissap        0,885      annuler ma commande   0,546
--     poulet braisé        0,852      vide mon panier       0,580
--     pizza                0,815      il est où le livreur  0,613
--     tacos                0,800      bonjour               0,649
--
-- Deux populations séparées par un fossé. 0,70 tombe au milieu, avec de la
-- marge des deux côtés.
--
-- Réglable depuis l'admin, parce que c'est ce nombre qui décide quand
-- l'assistant est appelé — donc à la fois la pertinence et le coût.

alter table platform_settings
  add column if not exists search_min_similarity numeric(3,2) not null default 0.70;

comment on column platform_settings.search_min_similarity is
  'En dessous, un produit n''est pas considéré comme trouvé. Monter rend la recherche plus stricte et renvoie plus souvent vers l''assistant ; descendre fait remonter des résultats hors sujet.';

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
      coalesce(radius_m, (select search_radius_m from platform_settings), 5000) as rayon,
      coalesce((select search_min_similarity from platform_settings), 0.70) as seuil
  ),
  origine as (
    select case
      when origin_lat is null or origin_lng is null then null
      else st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography
    end as point
  ),
  -- Périmètre commun : boutique approuvée, produit disponible, et dans le
  -- rayon si une position est fournie. La catégorie accepte une racine comme
  -- une feuille — les produits pendent aux feuilles depuis la migration.
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
    from candidats c, parametres pa
    where query_embedding is not null
      and c.embedding is not null
      -- Le seuil qui manquait. Sans lui, une requête qui n'a rien à voir
      -- avec le catalogue rend quand même ses huit plus proches voisins.
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
