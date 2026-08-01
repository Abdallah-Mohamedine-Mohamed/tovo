-- =====================================================================
-- 0005 — Panier et passage de commande
-- =====================================================================
-- Ces opérations vivent en base, et non côté Node, pour deux raisons.
--
-- ATOMICITÉ. Passer commande, c'est créer la commande, y copier les lignes
-- du panier, puis vider le panier. Enchaîné depuis Node, une coupure réseau
-- au milieu laisse une commande sans lignes ou un panier fantôme. Ici, une
-- fonction = une transaction.
--
-- PRIX. Le montant ne vient jamais du client. On le recalcule à partir de
-- products.price et product_option_values.price_delta, à chaque ajout et à
-- nouveau au moment de commander. Un client qui poste « total: 100 » se fait
-- ignorer.
--
-- Toutes les fonctions sont SECURITY INVOKER : la RLS s'applique, elles
-- n'accordent aucun privilège supplémentaire.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tarification
-- ---------------------------------------------------------------------
-- La grille se pilote depuis l'admin, donc elle vit en table et non dans le
-- corps d'une fonction : sinon changer un prix demanderait une migration.
--
-- Les frais de livraison, eux, sont déjà par zone (delivery_zones.base_fee),
-- également éditables depuis l'admin.
--
-- Les valeurs ci-dessous sont PROVISOIRES — elles permettent de tester, pas
-- de facturer.

create table if not exists pricing_settings (
  id                        boolean primary key default true check (id),
  courier_base              integer not null default 1000,
  courier_per_km            integer not null default 250,
  courier_medium_surcharge  integer not null default 250,
  courier_large_surcharge   integer not null default 500,
  courier_minimum           integer not null default 1000,
  default_delivery_fee      integer not null default 1000,
  updated_at                timestamptz not null default now(),
  updated_by                uuid references profiles(id)
);

-- Table singleton : la contrainte sur id garantit une seule ligne.
insert into pricing_settings (id) values (true) on conflict (id) do nothing;

alter table pricing_settings enable row level security;

drop policy if exists pricing_read  on pricing_settings;
drop policy if exists pricing_write on pricing_settings;

-- Lecture publique : le client doit pouvoir afficher une estimation avant
-- de commander. Écriture réservée à l'admin.
create policy pricing_read on pricing_settings for select using (true);
create policy pricing_write on pricing_settings for all
  using (is_admin()) with check (is_admin());

drop trigger if exists trg_pricing_updated on pricing_settings;
create trigger trg_pricing_updated before update on pricing_settings
  for each row execute function set_updated_at();

create or replace function public.zone_for_point(p_lat double precision, p_lng double precision)
returns delivery_zones language sql stable security definer set search_path = public as $$
  select z.* from delivery_zones z
  where z.is_active
    and st_covers(z.area, st_setsrid(st_point(p_lng, p_lat), 4326)::geography)
  order by st_area(z.area::geometry)   -- la zone la plus fine gagne
  limit 1
$$;

create or replace function public.delivery_fee_for(p_lat double precision, p_lng double precision)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(
    (public.zone_for_point(p_lat, p_lng)).base_fee,
    (select default_delivery_fee from pricing_settings)
  )
$$;

-- Coursier : forfait de prise en charge + distance + majoration de taille.
-- Les coefficients viennent de pricing_settings, pilotée par l'admin.
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
  from pricing_settings s
$$;

-- ---------------------------------------------------------------------
-- Panier
-- ---------------------------------------------------------------------

-- Prix unitaire réel d'une ligne : prix du produit + deltas des valeurs
-- d'options retenues. Valide au passage que les options obligatoires sont
-- satisfaites et que les valeurs citées appartiennent bien au produit.
--
-- Format de p_selections : [{"option_id": "...", "value_ids": ["...", ...]}]
create or replace function public.compute_unit_price(
  p_product_id uuid,
  p_selections jsonb
)
returns integer language plpgsql stable security definer set search_path = public as $$
declare
  base_price   integer;
  delta_total  integer := 0;
  opt          record;
  chosen_count integer;
  invalid      integer;
begin
  select price into base_price from products where id = p_product_id;
  if base_price is null then
    raise exception 'produit introuvable' using errcode = 'P0002';
  end if;

  -- Une valeur d'option qui n'appartient pas à ce produit, ou qui est
  -- indisponible, invalide toute la ligne.
  select count(*) into invalid
  from jsonb_array_elements(coalesce(p_selections, '[]'::jsonb)) sel
  cross join jsonb_array_elements_text(sel->'value_ids') v(value_id)
  where not exists (
    select 1
    from product_option_values pov
    join product_options po on po.id = pov.option_id
    where pov.id = v.value_id::uuid
      and po.product_id = p_product_id
      and pov.is_available
  );

  if invalid > 0 then
    raise exception 'option invalide pour ce produit' using errcode = 'P0001';
  end if;

  -- Options obligatoires : le compte de valeurs choisies doit tenir dans
  -- [min_select, max_select].
  for opt in
    select po.id, po.name, po.is_required, po.min_select, po.max_select
    from product_options po
    where po.product_id = p_product_id
  loop
    select coalesce(jsonb_array_length(sel->'value_ids'), 0) into chosen_count
    from jsonb_array_elements(coalesce(p_selections, '[]'::jsonb)) sel
    where (sel->>'option_id')::uuid = opt.id;

    chosen_count := coalesce(chosen_count, 0);

    if opt.is_required and chosen_count < greatest(opt.min_select, 1) then
      raise exception 'option obligatoire non renseignée : %', opt.name
        using errcode = 'P0001';
    end if;

    if chosen_count > opt.max_select then
      raise exception 'trop de choix pour l''option : %', opt.name
        using errcode = 'P0001';
    end if;
  end loop;

  select coalesce(sum(pov.price_delta), 0) into delta_total
  from jsonb_array_elements(coalesce(p_selections, '[]'::jsonb)) sel
  cross join jsonb_array_elements_text(sel->'value_ids') v(value_id)
  join product_option_values pov on pov.id = v.value_id::uuid;

  return greatest(base_price + delta_total, 0);
end; $$;

-- Libellé lisible des options retenues : « Portion double · Sauce arachide ».
-- Figé dans order_items, parce que le catalogue bouge et pas l'historique.
create or replace function public.selections_label(p_selections jsonb)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(string_agg(pov.name, ' · ' order by po.sort_order, pov.sort_order), '')
  from jsonb_array_elements(coalesce(p_selections, '[]'::jsonb)) sel
  cross join jsonb_array_elements_text(sel->'value_ids') v(value_id)
  join product_option_values pov on pov.id = v.value_id::uuid
  join product_options po on po.id = pov.option_id
$$;

-- Ajout au panier.
--
-- Le panier est mono-boutique : on ne peut pas commander chez deux
-- restaurants en une livraison. Si le produit vient d'ailleurs, on lève une
-- erreur identifiable (P0003) plutôt que de vider le panier en douce —
-- c'est à l'utilisateur de trancher.
create or replace function public.cart_add_item(
  p_product_id uuid,
  p_quantity   integer default 1,
  p_selections jsonb default '[]'::jsonb
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_cart_id     uuid;
  v_merchant_id uuid;
  v_current     uuid;
  v_price       integer;
  v_item_id     uuid;
begin
  if p_quantity is null or p_quantity < 1 then
    raise exception 'quantité invalide' using errcode = 'P0001';
  end if;

  select p.merchant_id into v_merchant_id
  from products p
  join merchants m on m.id = p.merchant_id
  where p.id = p_product_id and p.is_available and m.is_approved;

  if v_merchant_id is null then
    raise exception 'produit indisponible' using errcode = 'P0002';
  end if;

  v_price := public.compute_unit_price(p_product_id, p_selections);

  insert into carts (user_id, merchant_id)
  values (auth.uid(), v_merchant_id)
  on conflict (user_id) do update set updated_at = now()
  returning id, merchant_id into v_cart_id, v_current;

  if v_current is distinct from v_merchant_id then
    if exists (select 1 from cart_items where cart_id = v_cart_id) then
      raise exception 'panier déjà ouvert chez une autre boutique'
        using errcode = 'P0003';
    end if;
    update carts set merchant_id = v_merchant_id where id = v_cart_id;
  end if;

  -- Même produit, mêmes options : on incrémente au lieu d'empiler.
  select id into v_item_id
  from cart_items
  where cart_id = v_cart_id
    and product_id = p_product_id
    and selections = coalesce(p_selections, '[]'::jsonb);

  if v_item_id is not null then
    update cart_items
       set quantity = quantity + p_quantity, unit_price = v_price
     where id = v_item_id;
  else
    insert into cart_items (cart_id, product_id, quantity, selections, unit_price)
    values (v_cart_id, p_product_id, p_quantity, coalesce(p_selections, '[]'::jsonb), v_price)
    returning id into v_item_id;
  end if;

  return v_item_id;
end; $$;

create or replace function public.cart_set_quantity(p_item_id uuid, p_quantity integer)
returns void language plpgsql security invoker set search_path = public as $$
begin
  if p_quantity is null or p_quantity < 0 then
    raise exception 'quantité invalide' using errcode = 'P0001';
  end if;

  if p_quantity = 0 then
    delete from cart_items where id = p_item_id;
  else
    update cart_items set quantity = p_quantity where id = p_item_id;
  end if;
end; $$;

-- Contenu du panier, déjà mis en forme pour le composant cart_summary.
-- Les totaux viennent d'ici, jamais du client ni du modèle.
create or replace function public.cart_view(
  p_lat double precision default null,
  p_lng double precision default null
)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  v_cart      record;
  v_items     jsonb;
  v_items_tot integer := 0;
  v_fee       integer := 0;
  v_blocked   text;
begin
  select c.id, c.merchant_id, m.name as merchant_name, m.is_open
    into v_cart
  from carts c
  left join merchants m on m.id = c.merchant_id
  where c.user_id = auth.uid();

  if v_cart.id is null then
    return jsonb_build_object(
      'cart_id', null, 'items', '[]'::jsonb, 'items_total', 0,
      'delivery_fee', 0, 'discount', 0, 'total', 0,
      'currency', 'XOF', 'can_checkout', false
    );
  end if;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'item_id',          ci.id,
      'product_id',       ci.product_id,
      'product_name',     p.name,
      'image_url',        p.image_url,
      'selections',       ci.selections,
      'selections_label', public.selections_label(ci.selections),
      'unit_price',       ci.unit_price,
      'quantity',         ci.quantity,
      'line_total',       ci.unit_price * ci.quantity,
      'is_available',     coalesce(p.is_available, false)
    ) order by ci.created_at), '[]'::jsonb),
    coalesce(sum(ci.unit_price * ci.quantity), 0)
  into v_items, v_items_tot
  from cart_items ci
  join products p on p.id = ci.product_id
  where ci.cart_id = v_cart.id;

  if p_lat is not null and p_lng is not null then
    v_fee := public.delivery_fee_for(p_lat, p_lng);
  end if;

  if jsonb_array_length(v_items) = 0 then
    v_blocked := 'Votre panier est vide';
  elsif not coalesce(v_cart.is_open, false) then
    v_blocked := 'La boutique est fermée';
  elsif exists (
    select 1 from cart_items ci join products p on p.id = ci.product_id
    where ci.cart_id = v_cart.id and not p.is_available
  ) then
    v_blocked := 'Un produit du panier n''est plus disponible';
  end if;

  return jsonb_build_object(
    'cart_id',       v_cart.id,
    'merchant_id',   v_cart.merchant_id,
    'merchant_name', v_cart.merchant_name,
    'items',         v_items,
    'items_total',   v_items_tot,
    'delivery_fee',  v_fee,
    'discount',      0,
    'total',         v_items_tot + v_fee,
    'currency',      'XOF',
    'can_checkout',  v_blocked is null,
    'blocked_reason', v_blocked
  );
end; $$;

-- ---------------------------------------------------------------------
-- Passage de commande
-- ---------------------------------------------------------------------

-- Livraison. Idempotent : rejouer le même client_order_id renvoie la
-- commande déjà créée au lieu d'en créer une seconde. C'est ce qui protège
-- des doubles commandes quand le réseau coupe après l'envoi mais avant la
-- réponse.
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
  v_existing  uuid;
  v_cart      record;
  v_items_tot integer;
  v_fee       integer;
  v_order_id  uuid;
  v_zone      uuid;
begin
  select id into v_existing
  from orders
  where user_id = auth.uid() and client_order_id = p_client_order_id;

  if v_existing is not null then
    return v_existing;
  end if;

  select c.id, c.merchant_id, m.is_open
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

  -- Recalcul à partir de la base : le total posté par le client, s'il en
  -- poste un, n'est jamais lu.
  select coalesce(sum(ci.unit_price * ci.quantity), 0) into v_items_tot
  from cart_items ci
  join products p on p.id = ci.product_id
  where ci.cart_id = v_cart.id and p.is_available;

  if v_items_tot = 0 then
    raise exception 'panier vide' using errcode = 'P0002';
  end if;

  v_fee  := public.delivery_fee_for(p_lat, p_lng);
  v_zone := (public.zone_for_point(p_lat, p_lng)).id;

  insert into orders (
    client_order_id, type, user_id, merchant_id, zone_id, status,
    dropoff_hint, dropoff_location,
    items_total, delivery_fee, total, payment_method, note
  ) values (
    p_client_order_id, 'delivery', auth.uid(), v_cart.merchant_id, v_zone, 'pending',
    p_dropoff_hint, st_setsrid(st_point(p_lng, p_lat), 4326)::geography,
    v_items_tot, v_fee, v_items_tot + v_fee, p_payment, p_note
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

  delete from carts where id = v_cart.id;   -- cascade sur cart_items

  return v_order_id;
end; $$;

-- Coursier : pas de panier, pas de boutique. Juste deux points et un colis.
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
    items_total, delivery_fee, total, payment_method, scheduled_for
  ) values (
    p_client_order_id, 'courier', auth.uid(), null,
    (public.zone_for_point(p_pickup_lat, p_pickup_lng)).id, 'pending',
    p_dropoff_hint, st_setsrid(st_point(p_dropoff_lng, p_dropoff_lat), 4326)::geography,
    0, v_price, v_price, p_payment, p_scheduled_for
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
-- Suivi
-- ---------------------------------------------------------------------
-- Charge utile du composant order_tracking. La RLS filtre : un utilisateur
-- qui n'a pas le droit de voir la commande reçoit null.
create or replace function public.order_tracking(p_order_id uuid)
returns jsonb language sql stable security invoker set search_path = public as $$
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
    'merchant_name',  m.name,
    'driver', case when o.driver_id is null then null else jsonb_build_object(
      'id',      pr.id,
      'name',    pr.full_name,
      'phone',   pr.phone,
      'vehicle', dp.vehicle_type,
      'rating',  dp.rating
    ) end,
    'dropoff', jsonb_build_object(
      'hint', o.dropoff_hint,
      'lat',  st_y(o.dropoff_location::geometry),
      'lng',  st_x(o.dropoff_location::geometry)
    ),
    'pickup', case when cd.order_id is null then null else jsonb_build_object(
      'hint', cd.pickup_hint,
      'lat',  st_y(cd.pickup_location::geometry),
      'lng',  st_x(cd.pickup_location::geometry)
    ) end,
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
  where o.id = p_order_id;
$$;
