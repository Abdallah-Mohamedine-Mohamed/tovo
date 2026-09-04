-- =====================================================================
-- 0040 — Chercher une photo par les photos
-- =====================================================================
-- Les 2 058 produits ont maintenant un vecteur calculé depuis leur image
-- (0039). Reste à s'en servir : la recherche par photo passait par les
-- mots-clés, faute de pouvoir comparer une image au catalogue.
--
-- CALIBRÉ SUR LES VRAIES PHOTOS DES CLIENTS, celles déposées dans
-- `search-images` — prises au téléphone, mal éclairées, cadrées de travers.
-- Calibrer sur les images de catalogue aurait donné un seuil trop
-- optimiste : deux photos studio sur fond blanc se ressemblent bien plus que
-- la table en bois d'un client et le fond blanc d'un boutiquier.
--
--   photo envoyée          1er résultat                    score   20e
--   souris (6 photos)      SOURIS SANS FIL HP W10          0,676   0,591
--                          … la bonne souris 6 fois sur 6  0,708   0,626
--   thé                    THE AU LAIT DE MATCHA           0,702   0,660
--   ordinateur portable    Lenovo ThinkPad L380            0,681   0,588
--   powerbank              Bunsey Powerbank 10000mAh       0,651   0,606
--   clavier + souris       Clavier et souris Lenovo        0,669   0,629
--
-- PAS DE SEUIL ABSOLU POSSIBLE, encore une fois : le plus faible des bons
-- premiers résultats note 0,651, sous le bruit de la meilleure photo qui
-- atteint 0,660 au vingtième rang. Les deux populations se chevauchent.
--
-- Donc le même remède qu'ailleurs — un plancher pour pouvoir ne RIEN
-- trouver, et une marge relative au meilleur score pour couper la traîne.
-- 0,62 laisse passer le plus faible des bons ; 0,04 garde ce qui talonne le
-- premier sans descendre dans le bruit.
--
-- FONCTION SÉPARÉE, et non un paramètre de plus sur search_products. Le
-- chemin photo n'a pas de branche lexicale — il n'y a aucun texte à
-- comparer — et mêler les deux obligerait à neutraliser la moitié de la
-- fonction à chaque appel. Deux questions différentes, deux fonctions.
--
-- Le réglage `search_min_similarity_image` de search_products devient sans
-- objet pour le client : il servait à comparer une image aux vecteurs de
-- TEXTE, ce que plus personne ne fera. Il reste en place pour le jour où un
-- appelant voudrait ce comportement, mais il ne décide plus de rien.

alter table platform_settings
  add column if not exists photo_search_min_similarity numeric(3,2) not null default 0.62;

comment on column platform_settings.photo_search_min_similarity is
  'Plancher de la recherche par PHOTO, sur l''échelle image-contre-image. Mesuré : un bon résultat note 0,651 à 0,708 sur de vraies photos de téléphone. Monter au-delà de 0,65 ferait rater des correspondances justes.';

alter table platform_settings
  add column if not exists photo_search_relative_margin numeric(3,2) not null default 0.04;

comment on column platform_settings.photo_search_relative_margin is
  'Écart toléré sous le meilleur score, pour la recherche par photo. Le plancher seul ne suffit pas : le bruit d''une photo nette dépasse le meilleur résultat d''une photo médiocre.';

create or replace function public.search_by_photo(
  query_embedding vector(1536),
  origin_lat      double precision default null,
  origin_lng      double precision default null,
  radius_m        integer default null,
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
      -- CINQ, et non les huit de la recherche écrite.
      --
      -- Mesuré sur les photos réelles : les premiers résultats sont justes,
      -- mais la queue se dégrade vite — une photo de thé remontait le bon
      -- thé, puis un Sprite et un chargeur iPhone. Resserrer la marge
      -- couperait cette queue au prix des alternatives justes : la photo
      -- d'ordinateur portable perdrait le DELL qui suit le ThinkPad.
      --
      -- Borner le nombre coûte moins cher. « Ce qui ressemble à votre
      -- photo » n'a pas besoin de huit propositions.
      coalesce(match_count, 5) as n,
      -- 0 ou null : aucune limite de distance, comme pour la recherche écrite.
      nullif(coalesce(radius_m, (select search_radius_m from platform_settings), 0), 0) as rayon,
      coalesce((select photo_search_min_similarity from platform_settings), 0.62) as seuil,
      coalesce((select photo_search_relative_margin from platform_settings), 0.04) as marge
  ),
  origine as (
    select case
      when origin_lat is null or origin_lng is null then null
      else st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography
    end as point
  ),
  candidats as (
    select p.id, 1 - (p.image_embedding <=> query_embedding) as sim
    from products p
    join merchants m on m.id = p.merchant_id
    cross join origine o
    cross join parametres pa
    where m.is_approved
      and p.is_available
      and p.image_embedding is not null
      and (pa.rayon is null or o.point is null or st_dwithin(m.location, o.point, pa.rayon))
    order by p.image_embedding <=> query_embedding
    limit 60
  ),
  retenus as (
    select c.id, c.sim
    from candidats c, parametres pa
    where c.sim >= pa.seuil
      and c.sim >= (select max(sim) from candidats) - pa.marge
  )
  select
    p.id, p.merchant_id, m.name,
    public.merchant_open_now(m.id),
    p.name, p.description, p.image_url, p.price, p.is_available,
    case when o.point is null then null
         else st_distance(m.location, o.point)::integer end,
    -- Ici le score EST la similarité, contrairement à search_products dont
    -- le score vient d'une fusion de deux classements. L'appelant peut donc
    -- juger de la qualité de la correspondance, et le dire au client.
    r.sim
  from retenus r
  join products p on p.id = r.id
  join merchants m on m.id = p.merchant_id
  cross join origine o
  order by public.merchant_open_now(m.id) desc, r.sim desc
  limit (select n from parametres);
$$;

notify pgrst, 'reload schema';
