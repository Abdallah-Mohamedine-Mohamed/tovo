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
  candidates as materialized (
    select product.id, product.merchant_id, merchant.name as merchant_name,
      public.merchant_open_now(merchant.id) as merchant_open,
      product.name, product.description, product.image_url, product.price,
      product.is_available, product.category_id,
      array(select regexp_replace(word, 's$', '') from unnest(regexp_split_to_array(
        public.texte_reduit(product.name), '[^a-z0-9]+')) word) as name_words,
      array(select regexp_replace(word, 's$', '') from unnest(regexp_split_to_array(
        public.texte_reduit(product.name || ' ' || coalesce(product.options_text, '')), '[^a-z0-9]+')) word) as all_words
    from products product
    join merchants merchant on merchant.id = product.merchant_id
    where merchant.is_approved and product.is_available
      and (p_merchants is null or product.merchant_id = any(p_merchants))
      and (p_category is null or product.category_id in (select id from categories_scope))
  ),
  exact_matches as materialized (
    select candidate.*,
      (select count(*) from words where word = any(candidate.name_words))::double precision as score
    from candidates candidate
    where btrim(coalesce(p_query, '')) = '' or (
      exists (select 1 from words)
      and not exists (select 1 from words where not (word = any(candidate.all_words)))
      and ((select count(*) from words) = 1 or exists (select 1 from words where word = any(candidate.name_words)))
    )
  ),
  similar_matches as (
    select candidate.*, result.score
    from public.search_products(
      query_text => p_query, query_embedding => p_embedding,
      radius_m => 0, filter_category => p_category, match_count => 200,
      filter_merchants => p_merchants
    ) result
    join candidates candidate on candidate.id = result.id
    where not exists (select 1 from exact_matches)
      and btrim(coalesce(p_query, '')) <> '' and p_embedding is not null
  ),
  matches as materialized (
    select * from exact_matches
    union all
    select * from similar_matches
  ),
  page as (
    select *, exists (select 1 from words where not (word = any(matches.name_words)))
      and not exists (select 1 from words where not (word = any(matches.all_words))) as requires_options
    from matches
    order by score desc, merchant_open desc, name, merchant_id, id
    offset greatest(coalesce(p_offset, 0), 0)
    limit least(greatest(coalesce(p_limit, 24), 1), 60)
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(page) - 'name_words' - 'all_words'
      order by score desc, merchant_open desc, name, merchant_id, id) from page), '[]'::jsonb),
    'total', (select count(*) from matches),
    'offset', greatest(coalesce(p_offset, 0), 0),
    'next_offset', case when greatest(coalesce(p_offset, 0), 0) + (select count(*) from page) < (select count(*) from matches)
      then greatest(coalesce(p_offset, 0), 0) + (select count(*) from page) else null end,
    'match_type', case when exists (select 1 from exact_matches) then 'exact' else 'similar' end
  );
$$;

notify pgrst, 'reload schema';
