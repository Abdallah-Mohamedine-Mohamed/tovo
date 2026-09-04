-- =====================================================================
-- 0038 — Être généreux quand on a trouvé, avare quand on tâtonne
-- =====================================================================
-- L'assistant dit maintenant la vérité — « Je n'ai pas de crème fraîche, il
-- y a du yaourt si ça peut dépanner » — mais le carrousel sous sa phrase
-- affichait cinq cartes : yaourt, steak à la crème, PIMENT FRAIS, chocolat
-- viennois, frites. La phrase était juste, l'image la démentait.
--
-- MESURE. Voisins de « crème fraîche », par écart au meilleur :
--
--     0,707  Frozen Yogurt              0,000
--     0,687  Crêpes sucrées             0,020
--     0,683  Steak à la Crème           0,025
--     0,664  Piment frais               0,043
--     0,642  Viande hachée              0,065
--
-- Et ceux de « jus de bissap » :
--
--     0,885  Jus de Bissap              0,000
--     0,858  Bissap                     0,027
--     0,837  Jus de Bissap              0,048
--     0,827  Jus Naturel                0,058
--
-- Les deux s'étalent sur la même largeur — 0,065 contre 0,058. Une marge
-- unique ne peut donc pas les distinguer : trop serrée, elle ampute le
-- bissap ; trop large, elle laisse passer le piment frais.
--
-- CE QUI LES SÉPARE N'EST PAS L'ÉCART, C'EST LE NIVEAU. À 0,885 on a trouvé,
-- et tout ce qui suit de près mérite d'être montré. À 0,707 on n'a rien
-- trouvé du tout — on rend le moins éloigné, et en montrer cinq donne à un
-- tâtonnement l'apparence d'un résultat.
--
-- D'où deux régimes. Au-dessus du niveau de confiance, la marge large de
-- 0036. En dessous, une marge serrée : seuls les quasi ex æquo du premier.
--
-- Vérifié sur douze requêtes :
--     crème fraîche        0,707  incertain   5 -> 1  (Frozen Yogurt)
--     écouteurs            0,673  incertain   9 -> 2  (les deux EarPods)
--     jus de bissap        0,885  sûr             7  (inchangé)
--     tacos                0,800  sûr            11  (inchangé)
--     parapluie en titane  0,443  —               0  (inchangé)
--
-- CE QU'ON PERD, ET C'EST ASSUMÉ : les synonymes lointains tombent. Pour
-- « écouteurs », les Samsung Galaxy Buds notent 0,620 — sous le Coca-Cola à
-- 0,645. Aucun réglage ne garde les Buds sans garder le Coca ; le vecteur ne
-- les classe pas dans cet ordre. Montrer deux EarPods justes vaut mieux que
-- sept articles dont cinq n'ont rien à y faire.

alter table platform_settings
  add column if not exists search_confidence_level numeric(3,2) not null default 0.75;

comment on column platform_settings.search_confidence_level is
  'Au-dessus de ce score, on considère que la recherche a TROUVÉ, et les résultats proches du premier sont tous montrés. En dessous, seuls les quasi ex æquo du premier sortent — montrer une longue liste donnerait à un tâtonnement l''apparence d''un résultat.';

alter table platform_settings
  add column if not exists search_relative_margin_weak numeric(4,3) not null default 0.015;

comment on column platform_settings.search_relative_margin_weak is
  'Marge appliquée quand le meilleur score reste sous le niveau de confiance. Volontairement étroite. Ne s''applique pas à la recherche par photo, dont les scores vivent sur une autre échelle.';

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
