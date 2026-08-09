-- =====================================================================
-- 0032 — Une photo ne se mesure pas sur l'échelle d'un mot
-- =====================================================================
-- La recherche par photo ne rendait JAMAIS rien. Pas « rarement » : jamais.
--
-- La cause vient de la migration 0024, qui a introduit un plancher de
-- pertinence de 0,70. Ce chiffre était mesuré, mais sur des requêtes ÉCRITES :
-- « jus de bissap » notait 0,885, « annuler ma commande » 0,546. J'ai appliqué
-- ce plancher à la branche vectorielle sans voir qu'elle sert aussi la
-- recherche par image, où les scores vivent sur une tout autre échelle.
--
-- MESURE, sur le catalogue réel — la photo officielle d'un produit comparée
-- à tout le catalogue :
--
--     Box Poulet Pané     le produit lui-même 0,490     50e résultat 0,363
--     Burger Poulet       le produit lui-même 0,430     50e résultat 0,327
--     Wrap Poulet         le produit lui-même 0,429     50e résultat 0,345
--
-- Toute la population tient entre 0,32 et 0,49. À 0,70, même la photo
-- officielle d'un produit ne retrouvait pas ce produit — vérifié.
--
-- C'est normal et non un défaut du modèle : comparer une image à un texte
-- ne donne pas les mêmes valeurs que comparer deux textes. Les deux chemins
-- ont besoin de leur propre plancher.
--
-- 0,38 se place au-dessus du bruit (0,33–0,36) et sous la vraie
-- correspondance (0,43–0,49). La marge est plus mince que côté texte parce
-- que la distribution l'est aussi ; c'est la nature du signal, pas un
-- réglage timide.

alter table platform_settings
  add column if not exists search_min_similarity_image numeric(3,2) not null default 0.38;

comment on column platform_settings.search_min_similarity_image is
  'Plancher de pertinence pour la recherche par PHOTO. Distinct du seuil textuel : comparer une image à un catalogue produit des scores bien plus bas (0,32 à 0,49 mesurés), et appliquer le seuil des mots y rejetait tout.';

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
      coalesce(radius_m, (select search_radius_m from platform_settings), 5000) as rayon,
      -- Le seuil dépend de CE QUI est comparé, et la fonction le sait déjà :
      -- une requête sans texte mais avec un vecteur ne peut venir que d'une
      -- photo. Aucun paramètre supplémentaire n'est nécessaire, donc aucun
      -- appelant à modifier.
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
