-- =====================================================================
-- 0075 — Deux articles de la constitution de Tovo (backend/src/ai/
-- constitution.ts, docs/CONSTITUTION.md), garantis par la base.
-- =====================================================================
--
-- ARTICLE 6 — « Un produit répond à la demande par ce qu'il EST, pas par un
-- ingrédient ou une option qu'on peut choisir dedans. »
--
-- Jusqu'ici, un mot seul (« merguez ») était cherché dans le nom ET dans les
-- options de chaque produit : tous les tacos dont la viande au choix peut être
-- « merguez » sortaient avec les vraies merguez (capture du 02/10 : « Tacos
-- bowl », « Tacos gratiné » dans l'Explorer). Désormais :
--   1. d'abord les produits dont le NOM contient au moins un mot demandé
--      (« Assiette de merguez », « Pizza merguez » ; et « tacos merguez »
--      trouve toujours les tacos dont une option est merguez, puisque
--      « tacos » est dans leur nom) ;
--   2. les produits trouvés SEULEMENT par une option ne sortent que s'il
--      n'existe aucun produit de ce nom — mieux qu'une page vide.
-- Le total et la pagination (« Parcourir les N autres produits ») suivent.
--
-- ARTICLE 9 — « Ce que le client a dit est gardé. » Une précision qu'aucune
-- option ne prévoit (« sans oignons ») est rangée dans notes_commande, et
-- part avec la commande, dans la note que la boutique lit. Le client la voit
-- et la modifie au panier.

create or replace function public.catalog_products_page(
  p_query text default '',
  p_embedding vector(1536) default null,
  p_merchants uuid[] default null,
  p_category uuid default null,
  p_offset integer default 0,
  p_limit integer default 24
)
returns jsonb
language sql stable security invoker set search_path = public as $$
  with recursive categories_scope as (
    select id from categories where id = p_category
    union all
    select child.id from categories child
    join categories_scope parent on child.parent_id = parent.id
  ),
  words as (
    select distinct regexp_replace(word, 's$', '') as word
    from unnest(regexp_split_to_array(public.texte_reduit(coalesce(p_query, '')), '[^a-z0-9]+')) word
    where length(word) >= 2
      and word <> all(array['de','du','des','le','la','les','un','une','au','aux','avec','et','je','veux','voudrais','cherche','moi','svp'])
  ),
  requete as (
    select
      array(select word from words) as q,
      array(select distinct regexp_replace(public.phonetique(word), 's$', '') from words) as qp,
      array_to_string(array(select word from words), ' ') as texte,
      btrim(coalesce(p_query, '')) = '' as vide
  ),
  candidates as materialized (
    select product.id, product.merchant_id, merchant.name as merchant_name,
      product.name, product.description, product.image_url, product.price,
      product.is_available, product.category_id,
      product.recherche_nom, product.recherche_tout, product.phon_nom, product.phon_tout,
      product.texte_recherche
    from products product
    join merchants merchant on merchant.id = product.merchant_id
    where merchant.is_approved and product.is_available
      and (p_merchants is null or product.merchant_id = any(p_merchants))
      and (p_category is null or product.category_id in (select id from categories_scope))
  ),
  -- 1. Le produit par ce qu'il EST : au moins un mot demandé dans son nom.
  exact_name as materialized (
    select candidate.*,
      (select count(*) from unnest(requete.q) w where w = any(candidate.recherche_nom))::double precision as score
    from candidates candidate, requete
    where requete.vide or (
      cardinality(requete.q) > 0
      and candidate.recherche_tout @> requete.q
      and candidate.recherche_nom && requete.q
    )
  ),
  phonetic_matches as materialized (
    select candidate.*,
      (select count(*) from unnest(requete.qp) w where w = any(candidate.phon_nom))::double precision * 0.9 as score
    from candidates candidate, requete
    where not requete.vide
      and candidate.id not in (select id from exact_name)
      and cardinality(requete.qp) > 0
      and candidate.phon_tout @> requete.qp
      and candidate.phon_nom && requete.qp
  ),
  -- 2. Par une option seulement : uniquement si aucun produit ne porte ce nom.
  par_options as materialized (
    select candidate.*, 0.7::double precision as score
    from candidates candidate, requete
    where not requete.vide
      and not exists (select 1 from exact_name)
      and not exists (select 1 from phonetic_matches)
      and cardinality(requete.q) > 0
      and (candidate.recherche_tout @> requete.q
        or (cardinality(requete.qp) > 0 and candidate.phon_tout @> requete.qp))
  ),
  exact_matches as materialized (
    select * from exact_name
    union all
    select * from par_options
  ),
  tolerant_matches as materialized (
    select candidate.*,
      (select count(*) from unnest(requete.qp) w where public.mot_proche(w, candidate.phon_nom))::double precision * 0.8 as score
    from candidates candidate, requete
    where not requete.vide
      and not exists (select 1 from exact_matches)
      and not exists (select 1 from phonetic_matches)
      and cardinality(requete.qp) > 0
      and not exists (select 1 from unnest(requete.qp) w where not public.mot_proche(w, candidate.phon_tout))
      and exists (select 1 from unnest(requete.qp) w where public.mot_proche(w, candidate.phon_nom))
  ),
  similar_matches as materialized (
    select candidate.*, result.score
    from public.search_products(
      query_text => p_query, query_embedding => p_embedding,
      radius_m => 0, filter_category => p_category, match_count => 200,
      filter_merchants => p_merchants
    ) result
    join candidates candidate on candidate.id = result.id
    where not exists (select 1 from exact_matches)
      and not exists (select 1 from phonetic_matches)
      and not exists (select 1 from tolerant_matches)
      and btrim(coalesce(p_query, '')) <> '' and p_embedding is not null
  ),
  fuzzy_matches as (
    select candidate.*, word_similarity(requete.texte, candidate.texte_recherche)::double precision as score
    from candidates candidate, requete
    where not exists (select 1 from exact_matches)
      and not exists (select 1 from phonetic_matches)
      and not exists (select 1 from tolerant_matches)
      and not exists (select 1 from similar_matches)
      and length(requete.texte) >= 3
      and word_similarity(requete.texte, candidate.texte_recherche)
        >= coalesce((select search_min_fuzzy from platform_settings), 0.5)
  ),
  matches as materialized (
    select * from exact_matches
    union all
    select * from phonetic_matches
    union all
    select * from tolerant_matches
    union all
    select * from similar_matches
    union all
    select * from fuzzy_matches
  ),
  ouvertures as (
    select merchant_id, public.merchant_open_now(merchant_id) as merchant_open
    from (select distinct merchant_id from matches) boutiques
  ),
  page as (
    select matches.*, ouvertures.merchant_open,
      (not (matches.recherche_nom @> requete.q) and matches.recherche_tout @> requete.q and cardinality(requete.q) > 0)
      or (not (matches.phon_nom @> requete.qp) and matches.phon_tout @> requete.qp and cardinality(requete.qp) > 0)
        as requires_options
    from matches
    join ouvertures using (merchant_id)
    cross join requete
    order by matches.score desc, ouvertures.merchant_open desc, matches.name, matches.merchant_id, matches.id
    offset greatest(coalesce(p_offset, 0), 0)
    limit least(greatest(coalesce(p_limit, 24), 1), 60)
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(
        to_jsonb(page) - 'recherche_nom' - 'recherche_tout' - 'phon_nom' - 'phon_tout' - 'texte_recherche'
        order by score desc, merchant_open desc, name, merchant_id, id) from page), '[]'::jsonb),
    'total', (select count(*) from matches),
    'offset', greatest(coalesce(p_offset, 0), 0),
    'next_offset', case when greatest(coalesce(p_offset, 0), 0) + (select count(*) from page) < (select count(*) from matches)
      then greatest(coalesce(p_offset, 0), 0) + (select count(*) from page) else null end,
    'match_type', case when exists (select 1 from exact_matches) or exists (select 1 from phonetic_matches)
      then 'exact' else 'similar' end
  );
$$;

-- ---------------------------------------------------------------------
-- Article 9 : la note de commande du client (une par client, celle de sa
-- prochaine commande). Écrite par le chat (« sans oignons ») ou par le
-- client au panier ; lue et vidée quand la commande part.
-- ---------------------------------------------------------------------
create table if not exists public.notes_commande (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  note     text not null check (length(note) between 1 and 500),
  maj_le   timestamptz not null default now()
);

alter table public.notes_commande enable row level security;

drop policy if exists notes_commande_proprietaire on public.notes_commande;
create policy notes_commande_proprietaire on public.notes_commande
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.notes_commande to authenticated;

notify pgrst, 'reload schema';
