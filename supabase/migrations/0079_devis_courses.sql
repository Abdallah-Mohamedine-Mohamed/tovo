-- 0079 — Le prix affiché sur la carte de course est le prix facturé (09/10).
--
-- Décision du fondateur : « ne fais pas changer le prix de la commande même
-- si le trajet change. Les prix des livraisons, je les configure depuis
-- l'admin. » Le prix vient TOUJOURS des réglages de l'admin (forfait ville,
-- barème à la distance), mais il est calculé UNE fois, quand Tovo montre la
-- carte, et gardé : un DEVIS. Si le client modifie ensuite un lieu, la
-- course garde le prix qu'il a lu.
--
-- Sécurité : seul le serveur crée un devis (clé de service). Le client ne
-- peut ni en créer, ni en lire, ni en modifier un (RLS sans aucune règle) :
-- la commande le lit par une fonction protégée, et seulement le sien, non
-- expiré, une seule fois.

create table if not exists public.devis_courses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  prix        integer not null check (prix >= 0),
  distance_m  integer,
  cree_le     timestamptz not null default now(),
  -- Une conversation rouverte bien plus tard : les tarifs ont pu changer.
  expire_le   timestamptz not null default now() + interval '6 hours',
  utilise_le  timestamptz
);
alter table public.devis_courses enable row level security;
-- Aucune règle : ni lecture ni écriture pour les clients.

create index if not exists devis_courses_user on public.devis_courses (user_id, cree_le desc);

-- Le prix d'un devis du client appelant, valable et pas encore utilisé.
-- Le marque utilisé : un devis ne paie qu'une course.
create or replace function public.prendre_devis_course(p_devis uuid)
returns table (prix integer, distance_m integer)
language plpgsql security definer set search_path = public as $$
begin
  return query
  update devis_courses d
     set utilise_le = now()
   where d.id = p_devis
     and d.user_id = auth.uid()
     and d.utilise_le is null
     and d.expire_le > now()
  returning d.prix, d.distance_m;
end; $$;

-- La commande de course, avec le devis (facultatif). Sans devis valable,
-- le prix est calculé comme avant, depuis les réglages de l'admin.
drop function if exists public.place_courier_order(
  uuid, text, double precision, double precision, text, double precision,
  double precision, parcel_size, payment_method, timestamptz, text, text, text, text
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
  p_devis uuid default null
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

notify pgrst, 'reload schema';
