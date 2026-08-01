-- =====================================================================
-- 0008 — orders.zone_id désigne la zone de COLLECTE
-- =====================================================================
-- Incohérence révélée par les tests d'exécution.
--
-- `zone_id` était rempli avec la zone du point de LIVRAISON. Or il ne sert
-- qu'à deux choses : filtrer le pool visible par un livreur, et
-- présélectionner les candidats au dispatch. Dans les deux cas, ce qui
-- compte est l'endroit où le livreur doit se rendre EN PREMIER — la
-- boutique, ou le point de prise en charge d'un colis.
--
-- Concrètement : une boutique à Yantala qui livre au Plateau écartait les
-- livreurs de Yantala, c'est-à-dire exactement ceux qui étaient à côté du
-- restaurant. Le client attendait pendant qu'un livreur du Plateau
-- traversait la ville pour aller chercher sa commande.
--
-- Les frais de livraison ne sont pas concernés : ils viennent de
-- `delivery_fee_for(dropoff)`, calculé indépendamment.
-- =====================================================================

create or replace function public.place_delivery_order(
  p_client_order_id uuid,
  p_dropoff_hint    text,
  p_lat             double precision,
  p_lng             double precision,
  p_payment         payment_method default 'cash',
  p_note            text default null
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_existing   uuid;
  v_cart       record;
  v_items_tot  integer;
  v_fee        integer;
  v_order_id   uuid;
  v_zone       uuid;
  v_distance   integer;
  v_commission integer;
  v_driver_pay integer;
begin
  select id into v_existing
  from orders
  where user_id = auth.uid() and client_order_id = p_client_order_id;

  if v_existing is not null then
    return v_existing;
  end if;

  select c.id, c.merchant_id, m.is_open, m.location
    into v_cart
  from carts c
  join merchants m on m.id = c.merchant_id
  where c.user_id = auth.uid();

  if v_cart.id is null then
    raise exception 'panier vide' using errcode = 'P0002';
  end if;

  if not v_cart.is_open then
    raise exception 'la boutique est fermée' using errcode = 'P0003';
  end if;

  select coalesce(sum(ci.unit_price * ci.quantity), 0) into v_items_tot
  from cart_items ci
  join products p on p.id = ci.product_id
  where ci.cart_id = v_cart.id and p.is_available;

  if v_items_tot = 0 then
    raise exception 'panier vide' using errcode = 'P0002';
  end if;

  -- Le tarif dépend d'où l'on livre.
  v_fee := public.delivery_fee_for(p_lat, p_lng);

  -- Le dispatch dépend d'où l'on collecte.
  v_zone := (public.zone_for_point(
    st_y(v_cart.location::geometry),
    st_x(v_cart.location::geometry)
  )).id;

  v_distance := st_distance(
    v_cart.location,
    st_setsrid(st_point(p_lng, p_lat), 4326)::geography
  )::integer;

  v_commission := public.commission_for(v_items_tot);
  v_driver_pay := public.driver_pay_for(v_distance);

  insert into orders (
    client_order_id, type, user_id, merchant_id, zone_id, status,
    dropoff_hint, dropoff_location,
    items_total, delivery_fee, total, payment_method, note,
    commission_amount, merchant_payout, driver_earning
  ) values (
    p_client_order_id, 'delivery', auth.uid(), v_cart.merchant_id, v_zone, 'pending',
    p_dropoff_hint, st_setsrid(st_point(p_lng, p_lat), 4326)::geography,
    v_items_tot, v_fee, v_items_tot + v_fee, p_payment, p_note,
    v_commission, v_items_tot - v_commission, v_driver_pay
  )
  returning id into v_order_id;

  insert into order_items (
    order_id, product_id, product_name, unit_price, quantity,
    selections, selections_label, line_total
  )
  select
    v_order_id, ci.product_id, p.name, ci.unit_price, ci.quantity,
    ci.selections, public.selections_label(ci.selections),
    ci.unit_price * ci.quantity
  from cart_items ci
  join products p on p.id = ci.product_id
  where ci.cart_id = v_cart.id and p.is_available;

  delete from carts where id = v_cart.id;

  return v_order_id;
end; $$;

-- `place_courier_order` utilisait déjà la zone de prise en charge : rien à
-- corriger de ce côté.

notify pgrst, 'reload schema';
