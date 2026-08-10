-- =====================================================================
-- 0034 — Rétablir « 0 = pas de limite », que 0032 avait effacé
-- =====================================================================
-- Toute recherche accompagnée d'une POSITION ne rendait plus rien. Sans
-- position elle fonctionnait. « Je veux un tacos » répondait « je ne trouve
-- pas de tacos » alors que O'TAKOSS en vend quatre tailles à 1 864 mètres.
--
-- C'est ma faute, et elle est nette. La migration 0027 avait donné un sens
-- à la valeur 0 : « tout le catalogue, quelle que soit la distance ». Elle
-- l'écrivait ainsi :
--
--     nullif(coalesce(radius_m, (select search_radius_m …), 0), 0) as rayon
--     ... and (pa.rayon is null or o.point is null or st_dwithin(…))
--
-- En écrivant 0032, j'ai repris le corps de la fonction depuis 0024 — la
-- version d'AVANT 0027 — et j'y ai posé le seuil des images. Le `nullif` a
-- disparu au passage, sans que rien ne le signale : la fonction compilait,
-- les tests passaient, et le réglage valait toujours 0.
--
-- Sauf que `coalesce(…, 5000)` ne retient pas 0 : `coalesce` ne remplace
-- que NULL. Le rayon valait donc zéro, et `st_dwithin(point, point, 0)`
-- n'est vrai pour rien. Chaque recherche géolocalisée filtrait le catalogue
-- entier à zéro mètre.
--
-- Trois symptômes, une seule cause : le texte, la photo et la note vocale
-- transmettent tous la position du client.
--
-- LEÇON : une fonction se reprend depuis sa DERNIÈRE version, jamais depuis
-- celle qu'on a sous les yeux. Le fichier 0024 était ouvert, il avait l'air
-- complet, il ne l'était plus.

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
      -- 0 ou null : aucune limite de distance. Le `nullif` extérieur est
      -- ce qui a manqué en 0032 ; sans lui, 0 devient un rayon de zéro
      -- mètre au lieu d'une absence de rayon.
      nullif(coalesce(radius_m, (select search_radius_m from platform_settings), 0), 0) as rayon,
      -- Le seuil dépend de CE QUI est comparé : une requête sans texte mais
      -- avec un vecteur ne peut venir que d'une photo, et les scores d'une
      -- image vivent sur une tout autre échelle que ceux d'un mot.
      case
        when coalesce(length(btrim(query_text)), 0) = 0 and query_embedding is not null
          then coalesce((select search_min_similarity_image from platform_settings), 0.38)
        else coalesce((select search_min_similarity from platform_settings), 0.70)
      end as seuil
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
  -- Ouvertes d'abord, puis la pertinence. Un plat parfaitement trouvé mais
  -- incommandable vaut moins qu'un plat correct qu'on peut avoir tout de
  -- suite.
  order by public.merchant_open_now(m.id) desc, f.score desc, p.price asc
  limit (select n from parametres);
$$;

-- ---------------------------------------------------------------------
-- Que la panne ne puisse pas revenir en silence
-- ---------------------------------------------------------------------
-- Un rayon strictement positif mais minuscule aurait le même effet qu'un
-- rayon nul, sans avoir l'excuse d'être un cas particulier. Cinq cents
-- mètres est déjà le minimum imposé par le formulaire d'administration ;
-- on le grave ici, où il protège aussi des écritures directes en base.
alter table platform_settings
  drop constraint if exists platform_settings_search_radius_m_check;

alter table platform_settings
  add constraint platform_settings_search_radius_m_check
  check (search_radius_m = 0 or search_radius_m >= 500);

notify pgrst, 'reload schema';
