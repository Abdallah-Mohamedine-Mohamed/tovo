-- =====================================================================
-- 0057 — La recherche, précalculée
-- =====================================================================
-- 0056 a rendu la recherche tolérante aux fautes… et lente : 4 à 5 s par
-- requête, mesuré le 23/09. À CHAQUE recherche, la base redécoupait le nom
-- de TOUS les produits en mots, recalculait leur forme phonétique mot par
-- mot, et demandait pour chacun si sa boutique était ouverte — avant même
-- de savoir s'il correspondait.
--
-- Désormais :
--   - mots, formes phonétiques et texte de ressemblance sont calculés UNE
--     fois, quand le produit est écrit (colonnes générées, à jour d'office
--     quand le nom, les variantes ou les options changent) ;
--   - des index GIN servent la recherche par mots et la ressemblance ;
--   - « ouverte maintenant ? » n'est demandé qu'aux boutiques des
--     RÉSULTATS, une fois par boutique.
-- Le comportement (ce qui est trouvé, dans quel ordre) est inchangé.

-- Découpe en mots réduits (minuscules, sans accents, sans « s » final).
create or replace function public.mots_recherche(entree text)
returns text[] language sql immutable parallel safe as $$
  select coalesce(array_agg(distinct regexp_replace(mot, 's$', '')) filter (where mot <> ''), '{}')
  from unnest(regexp_split_to_array(public.texte_reduit(coalesce(entree, '')), '[^a-z0-9]+')) mot
$$;

-- Même découpe, en forme phonétique (0056).
create or replace function public.mots_phonetiques(entree text)
returns text[] language sql immutable parallel safe as $$
  select coalesce(array_agg(distinct regexp_replace(public.phonetique(mot), 's$', '')) filter (where mot <> ''), '{}')
  from unnest(regexp_split_to_array(public.texte_reduit(coalesce(entree, '')), '[^a-z0-9]+')) mot
$$;

alter table products
  add column if not exists recherche_nom text[] generated always as
    (public.mots_recherche(name || ' ' || coalesce(search_aliases, ''))) stored,
  add column if not exists recherche_tout text[] generated always as
    (public.mots_recherche(name || ' ' || coalesce(search_aliases, '') || ' ' || coalesce(options_text, ''))) stored,
  add column if not exists phon_nom text[] generated always as
    (public.mots_phonetiques(name || ' ' || coalesce(search_aliases, ''))) stored,
  add column if not exists phon_tout text[] generated always as
    (public.mots_phonetiques(name || ' ' || coalesce(search_aliases, '') || ' ' || coalesce(options_text, ''))) stored,
  add column if not exists texte_recherche text generated always as
    (public.texte_reduit(name || ' ' || coalesce(search_aliases, ''))) stored;

create index if not exists idx_products_recherche_tout on products using gin (recherche_tout);
create index if not exists idx_products_phon_tout on products using gin (phon_tout);
create index if not exists idx_products_texte_recherche on products using gin (texte_recherche gin_trgm_ops);

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
      and btrim(coalesce(p_query, '')) <> '' and p_embedding is not null
  ),
  fuzzy_matches as (
    select candidate.*, word_similarity(requete.texte, candidate.texte_recherche)::double precision as score
    from candidates candidate, requete
    where not exists (select 1 from exact_matches)
      and not exists (select 1 from phonetic_matches)
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
