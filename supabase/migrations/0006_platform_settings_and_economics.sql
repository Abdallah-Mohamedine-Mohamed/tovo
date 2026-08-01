-- =====================================================================
-- 0006 — Paramètres de plateforme et économie des commandes
-- =====================================================================
-- Deux corrections de fond.
--
-- 1. TOUT CE QUI EST MÉTIER SORT DU CODE.
--    « L'admin configure tout » implique qu'aucun paramètre métier ne vive
--    dans un corps de fonction. pricing_settings devient platform_settings
--    et absorbe les valeurs que j'avais codées en dur : rayons de recherche,
--    nombre de résultats renvoyés à l'IA, paramètres de dispatch, fenêtres
--    de rétention.
--
-- 2. L'ÉCONOMIE N'ÉTAIT PAS MODÉLISÉE.
--    Rien ne disait ce que Tovo prélève, ce que le livreur gagne, ni ce
--    qu'on doit à la boutique. L'app savait faire livrer un plat, pas
--    gagner d'argent.
--
--    Commission et rémunération sont FIGÉES sur la commande au moment où
--    elle passe. Si l'admin change la grille demain, les commandes d'hier
--    ne bougent pas — sinon la comptabilité devient une fiction.
-- =====================================================================

do $$ begin
  create type commission_mode as enum ('percent', 'flat');
exception when duplicate_object then null; end $$;

do $$ begin
  create type driver_pay_mode as enum ('flat', 'distance');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- platform_settings
-- ---------------------------------------------------------------------

alter table if exists pricing_settings rename to platform_settings;

alter table platform_settings
  -- Économie ------------------------------------------------------------
  add column if not exists commission_mode    commission_mode not null default 'percent',
  add column if not exists commission_percent numeric(5,2)    not null default 30.00,
  add column if not exists commission_flat    integer         not null default 300,
  add column if not exists driver_pay_mode    driver_pay_mode not null default 'flat',
  add column if not exists driver_pay_base    integer         not null default 500,
  add column if not exists driver_pay_per_km  integer         not null default 100,
  -- Recherche -----------------------------------------------------------
  add column if not exists search_radius_m      integer not null default 5000,
  add column if not exists search_result_limit  integer not null default 8,
  add column if not exists compare_radius_m     integer not null default 8000,
  -- Dispatch ------------------------------------------------------------
  add column if not exists dispatch_candidates  integer not null default 3,
  add column if not exists dispatch_timeout_s   integer not null default 45,
  add column if not exists dispatch_max_radius_m integer not null default 6000,
  -- Rétention -----------------------------------------------------------
  add column if not exists location_retention_h integer not null default 24,
  add column if not exists search_image_retention_h integer not null default 24;

alter table platform_settings
  add constraint platform_settings_commission_range
  check (commission_percent >= 0 and commission_percent <= 100)
  not valid;

-- Configuration de départ, arbitrée par Mohamedine le 01/08/2026 :
-- 30 % du panier, ou 300 XOF au forfait selon le mode retenu.
-- Écrite explicitement et non laissée aux valeurs par défaut, pour que la
-- migration produise le même état qu'elle s'applique à une base neuve ou à
-- une base où les colonnes existaient déjà.
--
-- Ces valeurs se pilotent ensuite depuis l'admin. Ne pas les remodifier ici :
-- une migration qui réécrit un réglage de production efface le travail de
-- l'administrateur.
update platform_settings
   set commission_mode    = 'percent',
       commission_percent = 30.00,
       commission_flat    = 300
 where id = true;

-- Les policies suivent le renommage automatiquement, mais on les renomme
-- pour que leur nom reste parlant.
alter policy pricing_read  on platform_settings rename to settings_read;
alter policy pricing_write on platform_settings rename to settings_write;

-- ---------------------------------------------------------------------
-- Montants figés sur la commande
-- ---------------------------------------------------------------------
-- commission_amount : ce que Tovo prélève à la boutique
-- merchant_payout   : ce qu'on doit à la boutique (items_total - commission)
-- driver_earning    : ce que le livreur gagne pour la course
--
-- Marge Tovo = commission_amount + delivery_fee - driver_earning

alter table orders
  add column if not exists commission_amount integer not null default 0,
  add column if not exists merchant_payout   integer not null default 0,
  add column if not exists driver_earning    integer not null default 0;

create or replace function public.commission_for(p_items_total integer)
returns integer language sql stable security definer set search_path = public as $$
  select least(
    p_items_total,
    case s.commission_mode
      when 'percent' then round(p_items_total * s.commission_percent / 100.0)::integer
      else s.commission_flat
    end
  )
  from platform_settings s
$$;

create or replace function public.driver_pay_for(p_distance_m integer)
returns integer language sql stable security definer set search_path = public as $$
  select case s.driver_pay_mode
    when 'flat' then s.driver_pay_base
    else (s.driver_pay_base
          + ceil(coalesce(p_distance_m, 0) / 1000.0) * s.driver_pay_per_km)::integer
  end
  from platform_settings s
$$;

-- ---------------------------------------------------------------------
-- Fonctions de tarification, relues depuis platform_settings
-- ---------------------------------------------------------------------

create or replace function public.delivery_fee_for(p_lat double precision, p_lng double precision)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(
    (public.zone_for_point(p_lat, p_lng)).base_fee,
    (select default_delivery_fee from platform_settings)
  )
$$;

create or replace function public.courier_price(
  p_distance_m integer,
  p_parcel parcel_size
)
returns integer language sql stable security definer set search_path = public as $$
  select greatest(
    s.courier_minimum,
    (s.courier_base
      + ceil(coalesce(p_distance_m, 0) / 1000.0) * s.courier_per_km
      + case p_parcel
          when 'small'  then 0
          when 'medium' then s.courier_medium_surcharge
          else               s.courier_large_surcharge
        end
    )::integer
  )
  from platform_settings s
$$;

-- ---------------------------------------------------------------------
-- Passage de commande, avec économie figée
-- ---------------------------------------------------------------------

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

  v_fee  := public.delivery_fee_for(p_lat, p_lng);
  v_zone := (public.zone_for_point(p_lat, p_lng)).id;

  -- Distance boutique → client, base de la rémunération au kilomètre.
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

-- Coursier : pas de boutique, donc pas de commission. Tovo encaisse la
-- course et rémunère le livreur dessus.
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
  p_parcel_note     text default null
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
    client_order_id, type, user_id, merchant_id, zone_id, status,
    dropoff_hint, dropoff_location,
    items_total, delivery_fee, total, payment_method, scheduled_for,
    commission_amount, merchant_payout, driver_earning
  ) values (
    p_client_order_id, 'courier', auth.uid(), null,
    (public.zone_for_point(p_pickup_lat, p_pickup_lng)).id, 'pending',
    p_dropoff_hint, st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography,
    0, v_price, v_price, p_payment, p_scheduled_for,
    0, 0, public.driver_pay_for(v_distance)
  )
  returning id into v_order_id;

  insert into courier_details (
    order_id, pickup_hint, pickup_location, parcel, parcel_note, distance_m
  ) values (
    v_order_id, p_pickup_hint,
    st_setsrid(st_point(p_pickup_lng, p_pickup_lat), 4326)::geography,
    p_parcel, p_parcel_note, v_distance
  );

  return v_order_id;
end; $$;

-- ---------------------------------------------------------------------
-- Ce que le livreur gagne réellement dans sa journée
-- ---------------------------------------------------------------------
-- driver_cash_ledger enregistrait ce qu'il ENCAISSE. Il faut aussi ce qu'il
-- GAGNE : les deux ne se compensent pas, il rend le cash et garde sa
-- rémunération.

create or replace function public.driver_daily_summary(target_driver uuid default null)
returns table (
  courses        integer,
  earned         integer,   -- rémunération des courses livrées
  cash_collected integer,   -- espèces encaissées, à reverser
  cash_settled   integer,   -- déjà reversé
  cash_due       integer    -- reste à reverser
)
language sql stable security invoker set search_path = public as $$
  with d as (select coalesce(target_driver, auth.uid()) as id),
  livrees as (
    select count(*)::integer as n, coalesce(sum(driver_earning), 0)::integer as pay
    from orders o, d
    where o.driver_id = d.id
      and o.status = 'delivered'
      and o.delivered_at >= date_trunc('day', now())
  ),
  cash as (
    select
      coalesce(sum(amount) filter (where amount > 0), 0)::integer as collected,
      coalesce(abs(sum(amount) filter (where amount < 0)), 0)::integer as settled,
      coalesce(sum(amount), 0)::integer as due
    from driver_cash_ledger l, d
    where l.driver_id = d.id
      and l.created_at >= date_trunc('day', now())
  )
  select livrees.n, livrees.pay, cash.collected, cash.settled, cash.due
  from livrees, cash;
$$;

-- ---------------------------------------------------------------------
-- Rétention pilotée par les paramètres
-- ---------------------------------------------------------------------

create or replace function public.purge_driver_locations()
returns void language plpgsql security definer set search_path = public as $$
declare
  h integer;
begin
  select location_retention_h into h from platform_settings;
  delete from driver_locations
  where recorded_at < now() - make_interval(hours => coalesce(h, 24));
end; $$;

create or replace function public.purge_search_images()
returns void language plpgsql security definer set search_path = public as $$
declare
  h integer;
begin
  select search_image_retention_h into h from platform_settings;
  delete from storage.objects
  where bucket_id = 'search-images'
    and created_at < now() - make_interval(hours => coalesce(h, 24));
end; $$;

notify pgrst, 'reload schema';
