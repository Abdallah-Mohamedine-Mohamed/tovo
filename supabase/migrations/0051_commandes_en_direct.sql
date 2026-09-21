do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
end $$;

alter table public.orders replica identity full;

create or replace function public.guard_status_transition()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_key text;
  v_ok boolean := false;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  v_key := old.status::text || '>' || new.status::text;

  if public.owns_merchant(old.merchant_id) then
    v_ok := v_key = any (array[
      'pending>confirmed',
      'confirmed>preparing',
      'confirmed>ready',
      'preparing>ready',
      'pending>cancelled',
      'confirmed>cancelled'
    ]);
  end if;

  if not v_ok
     and old.driver_id is null
     and new.driver_id = auth.uid()
     and v_key = 'ready>assigned'
     and public.my_role() = 'driver' then
    v_ok := true;
  end if;

  if not v_ok and old.driver_id = auth.uid() then
    v_ok := v_key = any (array[
      'assigned>picked_up',
      'assigned>delivering',
      'picked_up>delivering',
      'delivering>delivered'
    ]);
  end if;

  if not v_ok and old.user_id = auth.uid() and old.driver_id is null then
    v_ok := v_key = any (array[
      'pending>cancelled',
      'confirmed>cancelled',
      'preparing>cancelled',
      'ready>cancelled'
    ]);
  end if;

  if not v_ok then
    raise exception 'transition % non autorisée', v_key using errcode = 'P0003';
  end if;

  return new;
end; $$;

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
    (public.zone_for_point(p_pickup_lat, p_pickup_lng)).id,
    case when p_scheduled_for is null or p_scheduled_for <= now()
      then 'ready'::order_status else 'pending'::order_status end,
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
