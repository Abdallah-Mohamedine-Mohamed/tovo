-- 0081 — Le livreur est cherché près du lieu de RETRAIT (11/10).
--
-- Décision du fondateur : pour une course « aller chercher » chez un lieu
-- connu (0080), le livreur va d'abord LÀ-BAS. C'est donc près de ce point
-- qu'on le cherche, pas près du client. Partout où la base prend « le point
-- de départ » d'une course, elle prend le retrait s'il est connu, sinon la
-- position envoyée comme avant (ancienne application, lieu inconnu) :
--   - la zone de la commande (zone du point de collecte, 0063) ;
--   - les livreurs prévenus (dispatch_candidates) ;
--   - la distance dans la liste des courses du livreur (driver_pool) ;
--   - les livreurs proposés à l'admin (admin_assignable_drivers) ;
--   - le départ sur la fiche admin (admin_order_detail).
-- Le prix ne change pas (devis 0079, forfait de l'admin).

create or replace function public.place_courier_order(
  p_client_order_id uuid,
  p_pickup_hint text,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dropoff_hint text,
  p_dropoff_lat double precision,
  p_dropoff_lng double precision,
  p_parcel parcel_size default 'small',
  p_payment payment_method default 'cash',
  p_scheduled_for timestamptz default null,
  p_parcel_note text default null,
  p_dropoff_contact text default null,
  p_pickup_contact text default null,
  p_mode text default 'deposer',
  p_devis uuid default null,
  p_retrait_lat double precision default null,
  p_retrait_lng double precision default null
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_existing uuid;
  v_order_id uuid;
  v_distance integer;
  v_price integer;
  v_mode text := coalesce(nullif(btrim(coalesce(p_mode, '')), ''), 'deposer');
  v_destination boolean := p_dropoff_lat is not null and p_dropoff_lng is not null;
  v_devis_prix integer;
  v_devis_distance integer;
begin
  select id into v_existing
  from orders
  where user_id = auth.uid() and client_order_id = p_client_order_id;

  if v_existing is not null then
    return v_existing;
  end if;

  if v_mode not in ('deposer', 'recuperer') then
    raise exception 'sorte de course inconnue : %', v_mode using errcode = '22023';
  end if;

  if p_pickup_lat is null or p_pickup_lng is null then
    raise exception 'position de prise en charge manquante' using errcode = '22023';
  end if;

  -- Le devis d'abord : le prix que le client a lu sur la carte.
  if p_devis is not null then
    select d.prix, d.distance_m into v_devis_prix, v_devis_distance
      from public.prendre_devis_course(p_devis) d;
  end if;

  if v_devis_prix is not null then
    v_price := v_devis_prix;
    v_distance := v_devis_distance;
  -- Récupérer : la distance n'est pas connue (le départ n'est qu'une
  -- description). Déposer sans destination : idem. Forfait ville.
  elsif v_destination and v_mode = 'deposer' then
    v_distance := st_distance(
      st_setsrid(st_point(p_pickup_lng, p_pickup_lat), 4326)::geography,
      st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography
    )::integer;
    v_price := public.courier_price(v_distance, coalesce(p_parcel, 'small'));
  else
    v_distance := null;
    select courier_city_flat into v_price from platform_settings;
  end if;

  insert into orders (
    client_order_id, type, user_id, merchant_id,
    zone_id, status,
    dropoff_hint, dropoff_location,
    items_total, delivery_fee, total, payment_method, scheduled_for,
    discount, commission_amount, driver_earning
  ) values (
    p_client_order_id, 'courier', auth.uid(), null,
    -- La zone du point de COLLECTE (0063) : le retrait s'il est connu.
    case when p_retrait_lat is not null and p_retrait_lng is not null
      then (public.zone_for_point(p_retrait_lat, p_retrait_lng)).id
      else (public.zone_for_point(p_pickup_lat, p_pickup_lng)).id end,
    case when p_scheduled_for is null or p_scheduled_for <= now()
      then 'ready'::order_status else 'pending'::order_status end,
    coalesce(
      nullif(btrim(coalesce(p_dropoff_hint, '')), ''),
      case when v_mode = 'recuperer' then 'Chez le client' else 'À voir avec le client' end
    ),
    case when v_destination
      then st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography
    end,
    0, v_price, v_price, coalesce(p_payment, 'cash'), p_scheduled_for,
    0, 0, public.driver_pay_for(v_distance)
  )
  returning id into v_order_id;

  insert into courier_details (
    order_id, pickup_hint, pickup_location, parcel, parcel_note, distance_m,
    pickup_contact, dropoff_contact, mode, retrait_location
  ) values (
    v_order_id,
    coalesce(
      nullif(btrim(coalesce(p_pickup_hint, '')), ''),
      case when v_mode = 'recuperer' then 'À préciser au téléphone' else 'Position du client' end
    ),
    st_setsrid(st_point(p_pickup_lng, p_pickup_lat), 4326)::geography,
    coalesce(p_parcel, 'small'), p_parcel_note, v_distance,
    nullif(btrim(coalesce(p_pickup_contact, '')), ''),
    nullif(btrim(coalesce(p_dropoff_contact, '')), ''),
    v_mode,
    -- Le vrai point de retrait (« aller chercher » chez une boutique
    -- connue) : celui où le livreur doit se rendre.
    case when p_retrait_lat is not null and p_retrait_lng is not null
      then st_setsrid(st_point(p_retrait_lng, p_retrait_lat), 4326)::geography end
  );

  return v_order_id;
end; $$;

create or replace function public.dispatch_candidates(p_order_id uuid)
returns table (
  driver_id  uuid,
  full_name  text,
  fcm_token  text,
  distance_m integer
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_order    record;
  v_origin   geography;
  v_limit    integer;
  v_radius   integer;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'réservé au dispatch' using errcode = '42501';
  end if;

  select o.id, o.zone_id, o.merchant_id, o.type, o.status
    into v_order
  from orders o where o.id = p_order_id;

  if v_order.id is null or v_order.status <> 'ready' then
    return;
  end if;

  select s.dispatch_candidates, s.dispatch_max_radius_m
    into v_limit, v_radius
  from platform_settings s;

  if v_order.type = 'courier' then
    select coalesce(cd.retrait_location, cd.pickup_location) into v_origin
    from courier_details cd where cd.order_id = p_order_id;
  else
    select m.location into v_origin
    from merchants m where m.id = v_order.merchant_id;
  end if;

  if v_origin is null then
    return;
  end if;

  return query
  select
    d.id,
    pr.full_name,
    d.fcm_token,
    st_distance(d.current_location, v_origin)::integer
  from driver_profiles d
  join profiles pr on pr.id = d.id
  where d.is_online
    and d.is_available
    and d.current_location is not null
    and public.zone_couvre(d.zone_id, v_order.zone_id)
    and st_dwithin(d.current_location, v_origin, v_radius)
    and (d.last_seen_at is null or d.last_seen_at > now() - interval '2 minutes')
  order by d.current_location <-> v_origin
  limit greatest(v_limit, 1);
end; $$;

create or replace function public.driver_pool()
returns table (
  id             uuid,
  type           order_type,
  status         order_status,
  total          integer,
  driver_earning integer,
  dropoff_hint   text,
  placed_at      timestamptz,
  merchant_id    uuid,
  merchant_name  text,
  attente_min    integer,
  can_accept     boolean,
  mode           text,
  pickup_hint    text,
  distance_m     integer
)
language sql stable security invoker set search_path = public as $$
  select
    o.id,
    o.type,
    o.status,
    o.total,
    o.driver_earning,
    o.dropoff_hint,
    o.placed_at,
    o.merchant_id,
    m.name,
    (extract(epoch from (now() - o.placed_at)) / 60)::integer,
    o.status in ('pending', 'confirmed', 'preparing', 'ready'),
    cd.mode,
    cd.pickup_hint,
    st_distance(
      (select dp.current_location from driver_profiles dp where dp.id = auth.uid()),
      coalesce(cd.retrait_location, cd.pickup_location, m.location)
    )::integer
  from orders o
  left join merchants m        on m.id = o.merchant_id
  left join courier_details cd on cd.order_id = o.id
  where o.status in ('pending', 'confirmed', 'preparing', 'ready')
    and o.driver_id is null
    and (o.scheduled_for is null or o.scheduled_for <= now())
    and o.placed_at > now() - make_interval(
      mins => (select order_stale_after_min from platform_settings)
    )
  order by
    -- Prêtes d'abord, puis en préparation, puis les plus anciennes.
    case o.status when 'ready' then 0 when 'preparing' then 1 when 'confirmed' then 2 else 3 end,
    o.placed_at asc
  limit 30;
$$;

create or replace function public.admin_assignable_drivers(p_order_id uuid)
returns table (
  driver_id    uuid,
  full_name    text,
  phone        text,
  is_online    boolean,
  is_available boolean,
  last_seen_at timestamptz,
  distance_m   integer
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_origin geography;
  v_order  record;
begin
  if not public.is_admin() then
    raise exception 'réservé aux administrateurs' using errcode = '42501';
  end if;

  select o.id, o.merchant_id, o.type into v_order from orders o where o.id = p_order_id;

  if v_order.type = 'courier' then
    select coalesce(cd.retrait_location, cd.pickup_location) into v_origin
    from courier_details cd where cd.order_id = p_order_id;
  else
    select m.location into v_origin
    from merchants m where m.id = v_order.merchant_id;
  end if;

  return query
  select
    d.id,
    pr.full_name,
    pr.phone,
    d.is_online,
    d.is_available,
    d.last_seen_at,
    case when v_origin is null or d.current_location is null then null
         else st_distance(d.current_location, v_origin)::integer end
  from driver_profiles d
  join profiles pr on pr.id = d.id
  order by
    d.is_available desc,
    d.is_online desc,
    case when v_origin is null or d.current_location is null then 1 else 0 end,
    st_distance(d.current_location, v_origin)
  limit 30;
end; $$;

create or replace function public.admin_order_detail(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when o.id is null then null else jsonb_build_object(
    'id',               o.id,
    'type',             o.type,
    'status',           o.status,
    'placed_at',        o.placed_at,
    'delivered_at',     o.delivered_at,
    -- Le temps d'attente est ce que l'admin regarde en premier : une
    -- commande de quarante minutes en « en attente » est un incident.
    'attente_min',      (extract(epoch from (now() - o.placed_at)) / 60)::integer,
    'note',             o.note,
    'cancelled_reason', o.cancelled_reason,

    'items_total',      o.items_total,
    'delivery_fee',     o.delivery_fee,
    'discount',         o.discount,
    'total',            o.total,
    'commission_amount', o.commission_amount,
    'merchant_payout',  o.merchant_payout,
    'driver_earning',   o.driver_earning,

    'payment_method',   o.payment_method,
    'payment_status',   o.payment_status,
    'payment_ref',      o.payment_ref,
    'payment_confirmed_at', o.payment_confirmed_at,
    -- Qui a déclaré l'encaissement : nul quand c'est Nita qui l'a constaté.
    'payment_confirmed_by', (
      select p.full_name from profiles p where p.id = o.payment_confirmed_by
    ),

    'client', (
      select jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.user_id
    ),
    'merchant', case when o.merchant_id is null then null else (
      select jsonb_build_object(
        'id', m.id, 'name', m.name, 'phone', m.phone,
        'address_hint', m.address_hint,
        'is_open', public.merchant_open_now(m.id)
      )
      from merchants m where m.id = o.merchant_id
    ) end,
    'driver', case when o.driver_id is null then null else (
      select jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.driver_id
    ) end,

    'dropoff', jsonb_build_object(
      'hint', o.dropoff_hint,
      'lat',  st_y(o.dropoff_location::geometry),
      'lng',  st_x(o.dropoff_location::geometry)
    ),
    'pickup', (
      select jsonb_build_object(
        'hint', cd.pickup_hint,
        'lat',  st_y(coalesce(cd.retrait_location, cd.pickup_location)::geometry),
        'lng',  st_x(coalesce(cd.retrait_location, cd.pickup_location)::geometry)
      )
      from courier_details cd where cd.order_id = o.id
    ),

    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',       p.name,
        'quantity',   oi.quantity,
        'unit_price', oi.unit_price,
        'line_total', oi.unit_price * oi.quantity,
        -- Le libellé est figé sur la ligne de commande, pas recalculé : il
        -- doit rester celui du jour de l'achat même si le boutiquier renomme
        -- ses options ensuite.
        'options',    oi.selections_label
      ) order by oi.id)
      from order_items oi
      join products p on p.id = oi.product_id
      where oi.order_id = o.id
    ), '[]'::jsonb),

    -- L'historique dit où le temps a été perdu : trente minutes entre
    -- « prête » et « livreur assigné » désigne un problème de dispatch, pas
    -- une cuisine lente.
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('status', h.status, 'at', h.created_at)
                       order by h.created_at)
      from order_status_history h where h.order_id = o.id
    ), '[]'::jsonb)
  ) end
  from orders o
  where o.id = p_order_id
    and public.is_admin()
$$;

notify pgrst, 'reload schema';
