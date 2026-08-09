-- =====================================================================
-- 0033 — À qui remettre le colis, et comment le joindre
-- =====================================================================
-- Une course coursier partait avec deux points GPS, une taille de colis et
-- rien d'autre. Le livreur arrivait à destination sans savoir à qui remettre
-- le paquet, ni comment appeler quelqu'un si personne n'ouvrait la porte.
--
-- À Niamey où l'adresse postale n'existe pas, c'est bloquant : le repère
-- amène dans le bon quartier, le téléphone fait le reste. Un livreur qui ne
-- peut pas appeler repart avec le colis.
--
-- Les colonnes existaient déjà — `courier_details.pickup_contact` et
-- `dropoff_contact` étaient prévues depuis le premier schéma. Rien ne les
-- remplissait : ni la fonction de création, ni le formulaire.

create or replace function public.place_courier_order(
  p_client_order_id uuid,
  p_pickup_hint     text,
  p_pickup_lat      double precision,
  p_pickup_lng      double precision,
  p_dropoff_hint    text,
  p_dropoff_lat     double precision,
  p_dropoff_lng     double precision,
  p_parcel          parcel_size default 'small',
  p_payment         payment_method default 'cash',
  p_scheduled_for   timestamptz default null,
  p_parcel_note     text default null,
  -- Ajoutés EN FIN de signature et avec une valeur par défaut : les
  -- paramètres nommés de PostgREST le permettent sans casser les appelants
  -- existants, et le déploiement du backend n'a donc pas à être simultané.
  p_dropoff_contact text default null,
  p_pickup_contact  text default null
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_existing uuid;
  v_order_id uuid;
  v_distance integer;
  v_price    integer;
begin
  select id into v_existing
  from orders
  where user_id = auth.uid() and client_order_id = p_client_order_id;

  if v_existing is not null then
    return v_existing;
  end if;

  v_distance := st_distance(
    st_setsrid(st_point(p_pickup_lng, p_pickup_lat), 4326)::geography,
    st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography
  )::integer;

  v_price := public.courier_price(v_distance, p_parcel);

  insert into orders (
    client_order_id, type, user_id, merchant_id,
    zone_id, status,
    dropoff_hint, dropoff_location,
    items_total, delivery_fee, total, payment_method, scheduled_for,
    discount, commission_amount, driver_earning
  ) values (
    p_client_order_id, 'courier', auth.uid(), null,
    (public.zone_for_point(p_pickup_lat, p_pickup_lng)).id, 'pending',
    p_dropoff_hint, st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography,
    0, v_price, v_price, p_payment, p_scheduled_for,
    0, 0, public.driver_pay_for(v_distance)
  )
  returning id into v_order_id;

  insert into courier_details (
    order_id, pickup_hint, pickup_location, parcel, parcel_note, distance_m,
    pickup_contact, dropoff_contact
  ) values (
    v_order_id, p_pickup_hint,
    st_setsrid(st_point(p_pickup_lng, p_pickup_lat), 4326)::geography,
    p_parcel, p_parcel_note, v_distance,
    nullif(btrim(coalesce(p_pickup_contact, '')), ''),
    nullif(btrim(coalesce(p_dropoff_contact, '')), '')
  );

  return v_order_id;
end; $$;

-- ---------------------------------------------------------------------
-- Les contacts remontent jusqu'au livreur
-- ---------------------------------------------------------------------
-- Les enregistrer ne sert à rien si personne ne les voit. `order_tracking`
-- alimente l'écran de course : c'est là qu'ils doivent apparaître, à côté du
-- point de retrait et du point de livraison.

create or replace function public.order_tracking(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_id',       o.id,
    'type',           o.type,
    'status',         o.status,
    'total',          o.total,
    'items_total',    o.items_total,
    'delivery_fee',   o.delivery_fee,
    'payment_method', o.payment_method,
    'payment_status', o.payment_status,
    'placed_at',      o.placed_at,
    'delivered_at',   o.delivered_at,
    'note',           o.note,
    'merchant_name',  m.name,

    'client', case when o.user_id = auth.uid() then null else (
      select jsonb_build_object('name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.user_id
    ) end,

    'merchant', case when o.merchant_id is null then null else (
      select jsonb_build_object(
        'name',  m2.name,
        'phone', m2.phone,
        'hint',  m2.address_hint,
        'lat',   st_y(m2.location::geometry),
        'lng',   st_x(m2.location::geometry)
      )
      from merchants m2 where m2.id = o.merchant_id
    ) end,

    'driver', case when o.driver_id is null then null else jsonb_build_object(
      'id',      pr.id,
      'name',    pr.full_name,
      'phone',   pr.phone,
      'vehicle', dp.vehicle_type,
      'rating',  dp.rating
    ) end,

    -- Le contact de destination prime sur celui du client : pour un colis,
    -- celui qui commande n'est presque jamais celui qui reçoit.
    'dropoff', jsonb_build_object(
      'hint',    o.dropoff_hint,
      'lat',     st_y(o.dropoff_location::geometry),
      'lng',     st_x(o.dropoff_location::geometry),
      'contact', cd.dropoff_contact
    ),
    'pickup', case when cd.order_id is null then null else jsonb_build_object(
      'hint',    cd.pickup_hint,
      'lat',     st_y(cd.pickup_location::geometry),
      'lng',     st_x(cd.pickup_location::geometry),
      'contact', cd.pickup_contact
    ) end,
    'parcel',      cd.parcel,
    'parcel_note', cd.parcel_note,

    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_name',     oi.product_name,
        'selections_label', oi.selections_label,
        'quantity',         oi.quantity,
        'line_total',       oi.line_total
      )) from order_items oi where oi.order_id = o.id
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('status', h.status, 'at', h.created_at)
                       order by h.created_at)
      from order_status_history h where h.order_id = o.id
    ), '[]'::jsonb)
  )
  from orders o
  left join merchants m        on m.id = o.merchant_id
  left join driver_profiles dp on dp.id = o.driver_id
  left join profiles pr        on pr.id = o.driver_id
  left join courier_details cd on cd.order_id = o.id
  where o.id = p_order_id
    and public.can_see_order(o.id);
$$;

notify pgrst, 'reload schema';
