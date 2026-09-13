-- =====================================================================
-- 0049 — Les restaurants ne sont pas un rayon autour du client
-- =====================================================================
-- Niamey est assez compacte pour que la livraison serve justement à faire
-- venir un repas éloigné. La position reste utile pour afficher la distance,
-- mais elle ne doit pas reléguer une bonne enseigne derrière une boutique
-- voisine sans rapport.
--
-- La fonction renvoyait aussi les commerçants sans aucun produit disponible.
-- Une carte vide mène inévitablement à « rien trouvé » après un second clic.

create or replace function public.category_merchants(
  p_category_id uuid,
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_limite      integer default 50
)
returns table (
  id            uuid,
  name          text,
  description   text,
  logo_url      text,
  address_hint  text,
  is_open       boolean,
  rating        numeric,
  prep_time_min integer,
  distance_m    integer
)
language sql stable security definer set search_path = public as $$
  with origine as (
    select case
      when p_lat is null or p_lng is null then null
      else st_setsrid(st_point(p_lng, p_lat), 4326)::geography
    end as point
  )
  select
    m.id, m.name, m.description, m.logo_url, m.address_hint,
    public.merchant_open_now(m.id),
    m.rating, m.prep_time_min,
    case when o.point is null then null
         else st_distance(m.location, o.point)::integer end
  from merchants m
  cross join origine o
  where m.is_approved
    and m.category_id = p_category_id
    and exists (
      select 1
      from products p
      left join categories c on c.id = p.category_id
      where p.merchant_id = m.id
        and p.is_available
        and (p.category_id = p_category_id or c.parent_id = p_category_id)
    )
  order by
    public.merchant_open_now(m.id) desc,
    m.rating desc,
    case when o.point is null then null
         else st_distance(m.location, o.point) end nulls last,
    m.name
  limit least(greatest(coalesce(p_limite, 50), 1), 100)
$$;

notify pgrst, 'reload schema';
