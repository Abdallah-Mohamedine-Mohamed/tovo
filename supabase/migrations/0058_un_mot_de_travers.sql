-- =====================================================================
-- 0058 — Un mot juste, un mot de travers
-- =====================================================================
-- Après 0056-0057, 98 % des fautes de frappe sont rattrapées. Ce qui rate
-- encore (banc scripts/recherche, 23/09) : « doble burger », « pan poulet »,
-- « broshet poulet » — un mot correct à côté d'un mot faux. L'exact et la
-- phonétique exigent que CHAQUE mot corresponde ; la ressemblance globale
-- est diluée par le mot correct.
--
-- Nouvelle étape, entre la phonétique et la recherche par le sens : chaque
-- mot de la requête doit être PROCHE d'un mot du produit — une faute pour
-- un mot de 4-5 lettres, deux au-delà, aucune en dessous — et commencer par
-- la même lettre (« bain » ne devient pas « pain »).

create extension if not exists fuzzystrmatch;

create or replace function public.mot_proche(mot text, mots text[])
returns boolean language sql immutable parallel safe set search_path = public, extensions as $$
  select exists (
    select 1 from unnest(mots) candidat
    where left(candidat, 1) = left(mot, 1)
      and abs(length(candidat) - length(mot)) <= 2
      and levenshtein(mot, candidat) <= case
        when length(mot) <= 3 then 0
        when length(mot) <= 5 then 1
        else 2
      end
  )
$$;

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
  exact_matches as materialized (
    select candidate.*,
      (select count(*) from unnest(requete.q) w where w = any(candidate.recherche_nom))::double precision as score
    from candidates candidate, requete
    where requete.vide or (
      cardinality(requete.q) > 0
      and candidate.recherche_tout @> requete.q
      and (cardinality(requete.q) = 1 or candidate.recherche_nom && requete.q)
    )
  ),
  -- En complément de l'exact (0056) : « doucounou » = Doukounou.
  phonetic_matches as materialized (
    select candidate.*,
      (select count(*) from unnest(requete.qp) w where w = any(candidate.phon_nom))::double precision * 0.9 as score
    from candidates candidate, requete
    where not requete.vide
      and candidate.id not in (select id from exact_matches)
      and cardinality(requete.qp) > 0
      and candidate.phon_tout @> requete.qp
      and (cardinality(requete.qp) = 1 or candidate.phon_nom && requete.qp)
  ),
  -- 0058 : chaque mot peut porter UNE petite faute (deux s'il est long),
  -- sur sa forme phonétique. « doble burger », « pan poulet », « broshet
  -- poulet » : un mot juste et un mot de travers. Seulement quand ni
  -- l'exact ni la phonétique n'ont rien trouvé.
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
  -- Une question par BOUTIQUE des résultats, plus une par produit du catalogue.
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

notify pgrst, 'reload schema';
