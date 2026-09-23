-- =====================================================================
-- 0053 — Un livreur, pas un formulaire
-- =====================================================================
-- Envoyer un colis exigeait deux points GPS, une taille et le numéro du
-- destinataire. Ce n'est pas comme ça qu'on fait à Niamey : on appelle un
-- livreur, il vient, et le reste se règle au téléphone.
--
-- Désormais seule la prise en charge est requise (la position du client).
-- La destination devient facultative POUR UN COLIS UNIQUEMENT : une
-- livraison de boutique la garde obligatoire, la contrainte y veille.
--
-- Sans destination, pas de distance, donc un tarif ville fixe, réglé par
-- l'admin. Avec destination, le calcul à la distance reste inchangé.

alter table platform_settings
  add column if not exists courier_city_flat integer not null default 1000,
  -- Le délai annoncé au client : « un livreur vous appelle dans les N min ».
  add column if not exists courier_callback_minutes integer not null default 7;

alter table orders alter column dropoff_location drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'orders_destination_hors_colis'
  ) then
    alter table orders add constraint orders_destination_hors_colis
      check (type = 'courier' or dropoff_location is not null);
  end if;
end $$;

-- Tarif et délai, lisibles par le backend sans ouvrir platform_settings.
create or replace function public.courier_city_offer()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'price',            s.courier_city_flat,
    'callback_minutes', s.courier_callback_minutes
  )
  from platform_settings s
$$;

grant execute on function public.courier_city_offer() to authenticated;

-- Même signature qu'en 0051 : les appelants existants ne changent pas.
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
  p_pickup_contact text default null
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_existing uuid;
  v_order_id uuid;
  v_distance integer;
  v_price integer;
  v_destination boolean := p_dropoff_lat is not null and p_dropoff_lng is not null;
begin
  select id into v_existing
  from orders
  where user_id = auth.uid() and client_order_id = p_client_order_id;

  if v_existing is not null then
    return v_existing;
  end if;

  if p_pickup_lat is null or p_pickup_lng is null then
    raise exception 'position de prise en charge manquante' using errcode = '22023';
  end if;

  if v_destination then
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
    coalesce(nullif(btrim(coalesce(p_dropoff_hint, '')), ''), 'À voir avec le client'),
    case when v_destination
      then st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography
    end,
    0, v_price, v_price, coalesce(p_payment, 'cash'), p_scheduled_for,
    0, 0, public.driver_pay_for(v_distance)
  )
  returning id into v_order_id;

  insert into courier_details (
    order_id, pickup_hint, pickup_location, parcel, parcel_note, distance_m,
    pickup_contact, dropoff_contact
  ) values (
    v_order_id,
    coalesce(nullif(btrim(coalesce(p_pickup_hint, '')), ''), 'Position du client'),
    st_setsrid(st_point(p_pickup_lng, p_pickup_lat), 4326)::geography,
    coalesce(p_parcel, 'small'), p_parcel_note, v_distance,
    nullif(btrim(coalesce(p_pickup_contact, '')), ''),
    nullif(btrim(coalesce(p_dropoff_contact, '')), '')
  );

  return v_order_id;
end; $$;

notify pgrst, 'reload schema';
