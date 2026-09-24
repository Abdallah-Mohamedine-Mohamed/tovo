-- ============================================================================
-- 0059 — Deux sortes de livreur
--
-- « Je veux un livreur » recouvrait deux demandes différentes :
--
--   DÉPOSER    — le livreur vient CHEZ MOI, je lui remets un colis, il le
--                porte ailleurs. Départ : ma position.
--   RÉCUPÉRER  — le livreur va CHERCHER quelque chose ailleurs (chez Moussa,
--                au marché) et me l'APPORTE. Arrivée : ma position.
--
-- Jusqu'ici, tout était « déposer » : le départ était toujours la position
-- du client. Un client qui voulait se faire apporter un colis n'avait aucun
-- moyen de le dire.
--
-- Pour « récupérer », l'adresse exacte du départ est rarement connue : on
-- n'a qu'une description (« chez Moussa, Harobanda ») et un numéro. Le livreur
-- appelle sur place. Le point enregistré comme départ reste donc la position
-- du client — c'est autour d'elle que le dispatch cherche un livreur, dans le
-- même quartier en général — mais le suivi et l'appli livreur ne l'exposent
-- PAS comme un itinéraire vers le départ (il y mènerait chez le client).
-- Prix : le forfait ville, puisque la distance n'est pas connue.
-- ============================================================================

alter table courier_details
  add column if not exists mode text not null default 'deposer';

alter table courier_details drop constraint if exists courier_details_mode_check;
alter table courier_details
  add constraint courier_details_mode_check check (mode in ('deposer', 'recuperer'));

-- Nouvelle signature : l'ancienne est retirée pour qu'aucun appel ne tombe
-- sur deux fonctions (erreur « could not choose », vue en 0055).
drop function if exists public.place_courier_order(
  uuid, text, double precision, double precision, text, double precision,
  double precision, parcel_size, payment_method, timestamptz, text, text, text
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
  p_mode text default 'deposer'
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_existing uuid;
  v_order_id uuid;
  v_distance integer;
  v_price integer;
  v_mode text := coalesce(nullif(btrim(coalesce(p_mode, '')), ''), 'deposer');
  v_destination boolean := p_dropoff_lat is not null and p_dropoff_lng is not null;
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

  -- Récupérer : la distance n'est pas connue (le départ n'est qu'une
  -- description). Déposer sans destination : idem. Forfait ville.
  if v_destination and v_mode = 'deposer' then
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
    pickup_contact, dropoff_contact, mode
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
    v_mode
  );

  return v_order_id;
end; $$;

-- Le suivi (client ET appli livreur) connaît la sorte de course. Pour
-- « récupérer », le départ n'a pas de coordonnées à suivre : elles ne sont
-- que la position du client, et un itinéraire y mènerait le livreur à tort.
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
      'rating',  dp.rating
    ) end,

    'dropoff', jsonb_build_object(
      'hint',    o.dropoff_hint,
      'lat',     st_y(o.dropoff_location::geometry),
      'lng',     st_x(o.dropoff_location::geometry),
      'contact', cd.dropoff_contact
    ),
    'pickup', case when cd.order_id is null then null else jsonb_build_object(
      'hint',    cd.pickup_hint,
      'lat',     case when cd.mode = 'recuperer' then null else st_y(cd.pickup_location::geometry) end,
      'lng',     case when cd.mode = 'recuperer' then null else st_x(cd.pickup_location::geometry) end,
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
