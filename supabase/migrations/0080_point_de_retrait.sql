-- 0080 — Le vrai point de retrait arrive au livreur (11/10).
--
-- Pour une course « aller chercher » (mode recuperer), la position envoyée
-- comme départ est celle du CLIENT : elle sert à rattacher la course à une
-- zone et à trouver un livreur proche, et elle ne change pas. Le lieu où le
-- livreur doit aller (« BOBA Plateau », « French Tacos ») n'existait qu'en
-- texte : le suivi du livreur effaçait la position (0069) pour ne pas
-- l'envoyer chez le client.
--
-- Maintenant, quand Tovo connaît le lieu (une boutique Tovo, un commerce de
-- l'annuaire, un repère), l'application l'envoie à part : retrait_location.
-- Le suivi le renvoie comme position du départ, et l'écran du livreur
-- propose l'itinéraire. Sans lui (lieu inconnu, ancienne application),
-- rien ne change : le livreur lit le texte et appelle le client.
--
-- Le prix ne change pas (devis 0079, forfait de l'admin).

alter table public.courier_details add column if not exists retrait_location geography(Point, 4326);

drop function if exists public.place_courier_order(
  uuid, text, double precision, double precision, text, double precision,
  double precision, parcel_size, payment_method, timestamptz, text, text, text, text, uuid
);

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
    (public.zone_for_point(p_pickup_lat, p_pickup_lng)).id,
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

create or replace function public.order_tracking(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_id',       o.id,
    'type',           o.type,
    'mode',           cd.mode,
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
      'rating',  dp.rating,
      'position', case when o.status in ('delivered', 'cancelled') then null else coalesce(
        (select jsonb_build_object(
            'lat',     st_y(dl.location::geometry),
            'lng',     st_x(dl.location::geometry),
            'heading', dl.heading,
            'at',      dl.recorded_at)
           from driver_locations dl
          where dl.order_id = o.id
          order by dl.recorded_at desc
          limit 1),
        case when dp.current_location is null then null else jsonb_build_object(
          'lat', st_y(dp.current_location::geometry),
          'lng', st_x(dp.current_location::geometry),
          'heading', null,
          'at', dp.last_seen_at)
        end)
      end
    ) end,

    'dropoff', jsonb_build_object(
      'hint',    o.dropoff_hint,
      'lat',     st_y(o.dropoff_location::geometry),
      'lng',     st_x(o.dropoff_location::geometry),
      'contact', cd.dropoff_contact
    ),
    'pickup', case when cd.order_id is null then null else jsonb_build_object(
      'hint',    cd.pickup_hint,
      -- « Aller chercher » : le point de retrait s'il est connu ; jamais la
      -- position du client (qui n'est que le point de recherche du livreur).
      'lat',     case when cd.mode = 'recuperer' then st_y(cd.retrait_location::geometry) else st_y(cd.pickup_location::geometry) end,
      'lng',     case when cd.mode = 'recuperer' then st_x(cd.retrait_location::geometry) else st_x(cd.pickup_location::geometry) end,
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
