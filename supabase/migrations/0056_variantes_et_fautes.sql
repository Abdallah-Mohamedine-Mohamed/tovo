-- =====================================================================
-- 0056 — Trouver le produit même mal écrit
-- =====================================================================
-- La voie rapide ne comparait que des mots IDENTIQUES (sans accents ni
-- pluriel). Mesuré sur le vrai catalogue (scripts/recherche) :
--   - une seule faute de frappe (« pizza rcevette »)      → 0 % trouvés ;
--   - écriture réaliste de client (« nougets », « atieke ») → 6 % trouvés.
-- Le client lisait « Je ne trouve pas » pour une lettre de travers.
--
-- Deux remèdes complémentaires :
--
--   1. `search_aliases` : les écritures connues d'un produit ou d'une
--      enseigne (attiéké → atieke, atchéké ; O'Takoss → otacos). Leurs mots
--      comptent exactement comme ceux du nom. Remplies par
--      scripts/recherche/variantes.ts, relisibles et corrigeables à la main.
--
--   2. Tolérance aux fautes : quand AUCUN mot ne correspond exactement, on
--      retient les noms ressemblants (trigrammes, pg_trgm). Couvre aussi les
--      produits sans variantes — ceux qu'un commerçant ajoute demain.
--      N'intervient qu'en dernier recours : une correspondance exacte ou par
--      le sens passe toujours avant.

alter table products  add column if not exists search_aliases text;
alter table merchants add column if not exists search_aliases text;

comment on column products.search_aliases is
  'Écritures alternatives (fautes courantes, orthographes locales), séparées par des « ; ». Cherchées comme le nom.';
comment on column merchants.search_aliases is
  'Écritures alternatives du nom de l''enseigne, séparées par des « ; ».';

create extension if not exists pg_trgm;

-- Forme phonétique : les écritures qui se PRONONCENT pareil se rejoignent.
-- doucounou = doukounou = dukunu ; kilishi = kilichi ; nougets = nuggets ;
-- otacos = otakoss ; gato = gâteau. Appliquée au nom ET à la requête, elle
-- couvre tout le catalogue — y compris un produit ajouté demain, sans
-- attendre qu'on lui génère des variantes. Volontairement prudente : pas de
-- règle sur an/en ou s/z, qui confondraient des mots différents.
create or replace function public.phonetique(entree text)
returns text language sql immutable strict parallel safe as $$
  select regexp_replace(
    replace(replace(replace(replace(replace(replace(replace(
      regexp_replace(public.texte_reduit(entree), 'c([aou])', 'k\1', 'g'),
      'qu', 'k'), 'ck', 'k'), 'ph', 'f'), 'sh', 'ch'), 'eau', 'o'), 'au', 'o'), 'ou', 'u'),
    '(.)\1+', '\1', 'g')
$$;

comment on function public.phonetique(text) is
  'Forme phonétique prudente pour la recherche : c/k/qu, ou=u, sh=ch, eau/au=o, ph=f, lettres doublées.';

-- Seuil de ressemblance, réglable sans migration.
alter table platform_settings
  add column if not exists search_min_fuzzy double precision not null default 0.5;

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
  -- La requête débarrassée des mots vides, pour la ressemblance.
  requete as (
    select array_to_string(array(select word from words), ' ') as texte
  ),
  mots_phon as (
    select distinct regexp_replace(public.phonetique(word), 's$', '') as word from words
  ),
  candidates as materialized (
    select product.id, product.merchant_id, merchant.name as merchant_name,
      public.merchant_open_now(merchant.id) as merchant_open,
      product.name, product.description, product.image_url, product.price,
      product.is_available, product.category_id,
      -- Les variantes comptent comme le nom.
      array(select regexp_replace(word, 's$', '') from unnest(regexp_split_to_array(
        public.texte_reduit(product.name || ' ' || coalesce(product.search_aliases, '')), '[^a-z0-9]+')) word) as name_words,
      array(select regexp_replace(word, 's$', '') from unnest(regexp_split_to_array(
        public.texte_reduit(product.name || ' ' || coalesce(product.search_aliases, '') || ' ' || coalesce(product.options_text, '')), '[^a-z0-9]+')) word) as all_words,
      array(select regexp_replace(public.phonetique(word), 's$', '') from unnest(regexp_split_to_array(
        public.texte_reduit(product.name || ' ' || coalesce(product.search_aliases, '')), '[^a-z0-9]+')) word) as name_phon,
      array(select regexp_replace(public.phonetique(word), 's$', '') from unnest(regexp_split_to_array(
        public.texte_reduit(product.name || ' ' || coalesce(product.search_aliases, '') || ' ' || coalesce(product.options_text, '')), '[^a-z0-9]+')) word) as all_phon,
      public.texte_reduit(product.name || ' ' || coalesce(product.search_aliases, '')) as texte_nom
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
  -- Même exigence que l'exact, sur la forme phonétique : « doucounou »
  -- trouve Doukounou comme si le client l'avait bien écrit. TOUJOURS en
  -- complément de l'exact, pas seulement à sa place : sinon une variante
  -- enregistrée sur une fiche (« dukunu » → Doukounou) cachait les autres
  -- fiches du même plat (« Doukounou (5 pièces) »).
  phonetic_matches as materialized (
    select candidate.*,
      (select count(*) from mots_phon where word = any(candidate.name_phon))::double precision * 0.9 as score
    from candidates candidate
    where btrim(coalesce(p_query, '')) <> ''
      and candidate.id not in (select id from exact_matches)
      and exists (select 1 from mots_phon)
      and not exists (select 1 from mots_phon where not (word = any(candidate.all_phon)))
      and ((select count(*) from mots_phon) = 1 or exists (select 1 from mots_phon where word = any(candidate.name_phon)))
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
  -- Dernier recours : les noms qui RESSEMBLENT à la requête.
  fuzzy_matches as (
    select candidate.*, word_similarity(requete.texte, candidate.texte_nom)::double precision as score
    from candidates candidate, requete
    where not exists (select 1 from exact_matches)
      and not exists (select 1 from phonetic_matches)
      and not exists (select 1 from similar_matches)
      and length(requete.texte) >= 3
      and word_similarity(requete.texte, candidate.texte_nom)
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
  page as (
    -- « Trouvé par une option » : sur les mots bruts, ou sur leur forme
    -- phonétique pour une correspondance phonétique.
    select *, (exists (select 1 from words where not (word = any(matches.name_words)))
        and not exists (select 1 from words where not (word = any(matches.all_words))))
      or (exists (select 1 from mots_phon where not (word = any(matches.name_phon)))
        and not exists (select 1 from mots_phon where not (word = any(matches.all_phon)))) as requires_options
    from matches
    order by score desc, merchant_open desc, name, merchant_id, id
    offset greatest(coalesce(p_offset, 0), 0)
    limit least(greatest(coalesce(p_limit, 24), 1), 60)
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(page) - 'name_words' - 'all_words' - 'name_phon' - 'all_phon' - 'texte_nom'
      order by score desc, merchant_open desc, name, merchant_id, id) from page), '[]'::jsonb),
    'total', (select count(*) from matches),
    'offset', greatest(coalesce(p_offset, 0), 0),
    'next_offset', case when greatest(coalesce(p_offset, 0), 0) + (select count(*) from page) < (select count(*) from matches)
      then greatest(coalesce(p_offset, 0), 0) + (select count(*) from page) else null end,
    -- Ressemblance = « suggestions proches » pour le client, jamais un
    -- « voici exactement ce que vous cherchez ».
    -- Phonétique = le même mot autrement écrit : « exact » pour le client.
    'match_type', case when exists (select 1 from exact_matches) or exists (select 1 from phonetic_matches)
      then 'exact' else 'similar' end
  );
$$;

notify pgrst, 'reload schema';
