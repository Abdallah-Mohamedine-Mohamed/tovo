create extension vector;
    create table categories(id uuid primary key, name text, parent_id uuid, slug text);
    create table merchants(id uuid primary key, name text, is_approved boolean, is_open boolean);
    create table products(id uuid primary key, merchant_id uuid, category_id uuid, name text, description text,
      image_url text, price int, is_available boolean default true, options_text text);
    create function texte_reduit(entree text) returns text language sql immutable as $$
      select translate(lower(entree), 'àâäéèêëîïôöùûüÿç', 'aaaeeeeiioouuuyc') $$;
    create function merchant_open_now(p_merchant_id uuid) returns boolean language sql stable as $$
      select is_open from merchants where id = p_merchant_id $$;
    create function search_products(query_text text, query_embedding vector(1536), radius_m integer,
      filter_category uuid, match_count integer, filter_merchants uuid[])
    returns table(id uuid, score double precision) language sql stable as $$
      select id, 0.9::double precision from products where name = 'Suggestion' $$;
