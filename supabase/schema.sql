-- =====================================================================
-- TOVO — Schéma Supabase v1
-- =====================================================================
-- À exécuter en premier dans l'éditeur SQL Supabase, en une seule fois.
--
-- Décisions structurantes (voir docs/tovo_project.md §Schéma) :
--   * orders.type = 'delivery' | 'courier'  → le service Coursier est
--     modélisé dès la v1, une commande n'a pas forcément d'order_items.
--   * Le panier est persistant (carts / cart_items), pas en mémoire backend.
--   * driver_locations est une table dédiée haute fréquence, séparée de
--     driver_profiles, pour ne pas déclencher les triggers métier ni
--     gonfler la WAL toutes les 10 secondes.
--   * products.embedding est l'unique espace vectoriel interrogé (texte).
--     La recherche par image passe par Vision → description → embedding
--     TEXTE, donc elle matche la même colonne. products.image_embedding
--     est réservée à un futur modèle multimodal et n'est ni peuplée ni
--     indexée en v1.
--   * Index vectoriels en HNSW et non ivfflat : ivfflat construit ses
--     listes à la création et donne un rappel médiocre sur table vide.
--   * orders.client_order_id : clé d'idempotence générée par Flutter.
--     Indispensable sur réseau instable.
-- =====================================================================

create extension if not exists postgis;
create extension if not exists vector;
create extension if not exists pgcrypto;

-- =====================================================================
-- 1. TYPES
-- =====================================================================

-- Un bloc par type : si tous partagent le même bloc, la première exception
-- annule la création des suivants et le script devient non rejouable.

do $$ begin
  create type user_role as enum ('client', 'driver', 'merchant', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_type as enum ('delivery', 'courier');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_status as enum (
    'pending',     -- créée, pas encore acceptée par la boutique
    'confirmed',   -- boutique a accepté
    'preparing',
    'ready',       -- prête, visible par les livreurs de la zone
    'assigned',    -- un livreur a accepté
    'picked_up',
    'delivering',
    'delivered',
    'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_method as enum ('cash', 'mobile_money');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_status as enum ('pending', 'paid', 'failed', 'refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type parcel_size as enum ('small', 'medium', 'large');
exception when duplicate_object then null; end $$;

do $$ begin
  create type cash_entry_type as enum ('collection', 'settlement', 'adjustment');
exception when duplicate_object then null; end $$;

-- =====================================================================
-- 2. UTILITAIRES
-- =====================================================================

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

-- my_role() et is_admin() sont définies plus bas, juste après la table
-- profiles : une fonction `language sql` voit son corps validé à la
-- création, elle ne peut donc pas référencer une table qui n'existe pas
-- encore. (Un corps plpgsql, lui, n'est pas validé — d'où la différence
-- de traitement avec les triggers ci-dessous.)

-- =====================================================================
-- 3. IDENTITÉ
-- =====================================================================

create table if not exists profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  role         user_role   not null default 'client',
  full_name    text        not null default '',
  phone        text unique,
  avatar_url   text,
  locale       text        not null default 'fr',
  legacy_id    text unique,             -- id 6ammart, pour l'ETL de migration
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

drop trigger if exists trg_profiles_updated on profiles;
create trigger trg_profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- Rôle de l'utilisateur courant. SECURITY DEFINER pour éviter la récursion
-- infinie des policies qui lisent profiles : sans cela, la policy de lecture
-- de profiles s'appellerait elle-même.
create or replace function public.my_role()
returns user_role language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

-- Création automatique du profil à l'inscription.
--
-- Le rôle est TOUJOURS 'client', jamais lu depuis raw_user_meta_data : les
-- métadonnées d'inscription sont contrôlées par le client, donc s'y fier
-- laisserait n'importe qui s'inscrire en 'admin'. La promotion en driver,
-- merchant ou admin passe par l'admin (service_role), après vérification.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, role, full_name, phone)
  values (
    new.id,
    'client',
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.phone
  )
  on conflict (id) do nothing;
  return new;
end; $$;

-- Même raison côté UPDATE : un utilisateur peut modifier son profil, mais
-- pas son propre rôle. Seul l'admin (ou la service_role, qui contourne la
-- RLS) peut le changer.
-- auth.uid() est null quand la requête vient de la service_role (jobs, ETL,
-- promotion d'un livreur par l'admin) : les triggers s'exécutent même pour
-- la service_role, contrairement à la RLS. Sans cette condition, plus
-- personne ne pourrait promouvoir qui que ce soit.
create or replace function public.guard_role_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role
     and auth.uid() is not null
     and not public.is_admin() then
    raise exception 'changement de rôle interdit';
  end if;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

drop trigger if exists trg_guard_role on profiles;
create trigger trg_guard_role
  before update of role on profiles
  for each row execute function guard_role_change();

-- Adresses sauvegardées. À Niamey l'adresse postale n'existe pas :
-- le point GPS fait foi, le texte n'est qu'un repère pour le livreur.
create table if not exists addresses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  label       text not null default 'Adresse',
  text_hint   text not null,             -- « Yantala, derrière la pharmacie Al Nour »
  location    geography(point, 4326) not null,
  is_default  boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists idx_addresses_user on addresses(user_id);
create index if not exists idx_addresses_loc  on addresses using gist(location);

-- =====================================================================
-- 4. ZONES & LIVREURS
-- =====================================================================

create table if not exists delivery_zones (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,              -- « Plateau », « Yantala », « Niamey 2000 »
  area       geography(polygon, 4326) not null,
  base_fee   integer not null default 500,   -- XOF, entier
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_zones_area on delivery_zones using gist(area);

create table if not exists driver_profiles (
  id                uuid primary key references profiles(id) on delete cascade,
  zone_id           uuid references delivery_zones(id) on delete set null,
  vehicle_type      text not null default 'moto',
  plate_number      text,
  is_online         boolean not null default false,
  is_available      boolean not null default true,  -- false = course en cours
  current_location  geography(point, 4326),
  last_seen_at      timestamptz,
  rating            numeric(2,1) not null default 5.0,
  fcm_token         text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

drop trigger if exists trg_driver_updated on driver_profiles;
create trigger trg_driver_updated before update on driver_profiles
  for each row execute function set_updated_at();

create index if not exists idx_drivers_online on driver_profiles(is_online, is_available)
  where is_online = true;
create index if not exists idx_drivers_loc on driver_profiles using gist(current_location);

-- Table haute fréquence : un ping toutes les 10 s par livreur en course.
-- Séparée de driver_profiles pour ne pas réveiller ses triggers.
-- Purger au-delà de 24 h (voir supabase/migrations/ pour le cron).
create table if not exists driver_locations (
  id         bigserial primary key,
  driver_id  uuid not null references driver_profiles(id) on delete cascade,
  order_id   uuid,                       -- FK ajoutée après création de orders
  location   geography(point, 4326) not null,
  heading    numeric(5,2),
  speed_kmh  numeric(5,2),
  recorded_at timestamptz not null default now()
);

create index if not exists idx_driver_locations_lookup
  on driver_locations(driver_id, recorded_at desc);

-- Cash livreur : il encaisse les espèces et reverse sa collecte.
-- Le solde du jour affiché dans l'app livreur se calcule ici.
create table if not exists driver_cash_ledger (
  id         uuid primary key default gen_random_uuid(),
  driver_id  uuid not null references driver_profiles(id) on delete cascade,
  order_id   uuid,                       -- FK ajoutée après création de orders
  entry_type cash_entry_type not null,
  amount     integer not null,           -- XOF, positif = encaissé, négatif = reversé
  note       text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_cash_driver_day
  on driver_cash_ledger(driver_id, created_at desc);

-- =====================================================================
-- 5. CATALOGUE
-- =====================================================================

create table if not exists categories (
  id          uuid primary key default gen_random_uuid(),
  parent_id   uuid references categories(id) on delete cascade,
  name        text not null,
  slug        text not null unique,
  icon        text,                       -- emoji ou nom d'icône
  image_url   text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists merchants (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references profiles(id) on delete cascade,
  category_id    uuid references categories(id) on delete set null,
  name           text not null,
  description    text,
  logo_url       text,
  cover_url      text,
  phone          text,
  address_hint   text not null default '',
  location       geography(point, 4326) not null,
  zone_id        uuid references delivery_zones(id) on delete set null,
  is_open        boolean not null default false,
  is_approved    boolean not null default false,
  opens_at       time,
  closes_at      time,
  prep_time_min  integer not null default 20,
  rating         numeric(2,1) not null default 5.0,
  rating_count   integer not null default 0,
  legacy_id      text unique,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

drop trigger if exists trg_merchants_updated on merchants;
create trigger trg_merchants_updated before update on merchants
  for each row execute function set_updated_at();

create index if not exists idx_merchants_loc      on merchants using gist(location);
create index if not exists idx_merchants_owner    on merchants(owner_id);
create index if not exists idx_merchants_category on merchants(category_id);
create index if not exists idx_merchants_open     on merchants(is_open, is_approved)
  where is_approved = true;

create table if not exists products (
  id                uuid primary key default gen_random_uuid(),
  merchant_id       uuid not null references merchants(id) on delete cascade,
  category_id       uuid references categories(id) on delete set null,
  name              text not null,
  description       text,
  image_url         text,
  image_description text,                -- généré par Gemini Vision, entre dans l'embedding
  price             integer not null check (price >= 0),   -- XOF entier, jamais de décimales
  compare_at_price  integer check (compare_at_price >= 0),
  is_available      boolean not null default true,
  stock_qty         integer,             -- null = stock non suivi
  tags              text[] not null default '{}',
  embedding         vector(1536),        -- espace TEXTE : name + description + image_description
  image_embedding   vector(1536),        -- RÉSERVÉ multimodal, non peuplé en v1
  legacy_id         text unique,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

drop trigger if exists trg_products_updated on products;
create trigger trg_products_updated before update on products
  for each row execute function set_updated_at();

create index if not exists idx_products_merchant on products(merchant_id);
create index if not exists idx_products_category on products(category_id);
create index if not exists idx_products_avail    on products(is_available)
  where is_available = true;

-- HNSW : rappel correct dès le premier produit inséré, contrairement à ivfflat.
create index if not exists idx_products_embedding
  on products using hnsw (embedding vector_cosine_ops);

create table if not exists product_options (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references products(id) on delete cascade,
  name         text not null,            -- « Sauce », « Portion »
  is_required  boolean not null default false,
  min_select   integer not null default 0,
  max_select   integer not null default 1,
  sort_order   integer not null default 0,
  check (min_select <= max_select)
);

create index if not exists idx_options_product on product_options(product_id);

create table if not exists product_option_values (
  id           uuid primary key default gen_random_uuid(),
  option_id    uuid not null references product_options(id) on delete cascade,
  name         text not null,
  price_delta  integer not null default 0,   -- XOF, peut être négatif
  is_available boolean not null default true,
  sort_order   integer not null default 0
);

create index if not exists idx_option_values_option on product_option_values(option_id);

-- Offres externes (Amazon, Jumia, boutiques hors plateforme) affichées
-- dans price_comparison en complément des partenaires. Jamais commandables :
-- is_orderable = false → l'UI affiche « Voir » et non « Commander ».
create table if not exists external_offers (
  id            uuid primary key default gen_random_uuid(),
  source        text not null,           -- « jumia », « amazon », ...
  source_url    text,
  title         text not null,
  image_url     text,
  price         integer not null check (price >= 0),
  currency      text not null default 'XOF',
  in_stock      boolean not null default true,
  embedding     vector(1536),
  fetched_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '24 hours'
);

create index if not exists idx_external_embedding
  on external_offers using hnsw (embedding vector_cosine_ops);
create index if not exists idx_external_expiry on external_offers(expires_at);

-- =====================================================================
-- 6. CONVERSATION
-- =====================================================================

create table if not exists conversations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  title       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

drop trigger if exists trg_conversations_updated on conversations;
create trigger trg_conversations_updated before update on conversations
  for each row execute function set_updated_at();

create index if not exists idx_conversations_user on conversations(user_id, updated_at desc);

create table if not exists messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references conversations(id) on delete cascade,
  role             text not null check (role in ('user', 'assistant', 'tool')),
  content          text not null default '',
  components       jsonb not null default '[]'::jsonb,  -- contrat UI, voir tovo_ui_contract.md
  tool_calls       jsonb,
  image_path       text,      -- chemin Storage. L'image ne transite JAMAIS en base64.
  created_at       timestamptz not null default now()
);

create index if not exists idx_messages_conversation
  on messages(conversation_id, created_at);

-- =====================================================================
-- 7. PANIER
-- =====================================================================

create table if not exists carts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  merchant_id uuid references merchants(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Un seul panier actif par utilisateur.
create unique index if not exists idx_carts_user_unique on carts(user_id);

drop trigger if exists trg_carts_updated on carts;
create trigger trg_carts_updated before update on carts
  for each row execute function set_updated_at();

create table if not exists cart_items (
  id          uuid primary key default gen_random_uuid(),
  cart_id     uuid not null references carts(id) on delete cascade,
  product_id  uuid not null references products(id) on delete cascade,
  quantity    integer not null default 1 check (quantity > 0),
  -- [{ "option_id": "...", "value_ids": ["...","..."] }]
  selections  jsonb not null default '[]'::jsonb,
  unit_price  integer not null,           -- prix produit + deltas, figé à l'ajout
  created_at  timestamptz not null default now()
);

create index if not exists idx_cart_items_cart on cart_items(cart_id);

-- =====================================================================
-- 8. COMMANDES
-- =====================================================================

create table if not exists orders (
  id                uuid primary key default gen_random_uuid(),
  -- Idempotence : généré par Flutter avant l'envoi. Un rejeu réseau
  -- retombe sur la même ligne au lieu de créer une deuxième commande.
  client_order_id   uuid not null,
  type              order_type not null default 'delivery',
  user_id           uuid not null references profiles(id) on delete restrict,
  merchant_id       uuid references merchants(id) on delete restrict,  -- null si courier
  driver_id         uuid references driver_profiles(id) on delete set null,
  zone_id           uuid references delivery_zones(id) on delete set null,
  status            order_status not null default 'pending',

  -- Destination (les deux types de commande en ont une)
  dropoff_hint      text not null,
  dropoff_location  geography(point, 4326) not null,

  -- Montants, tous en XOF entiers
  items_total       integer not null default 0 check (items_total >= 0),
  delivery_fee      integer not null default 0 check (delivery_fee >= 0),
  discount          integer not null default 0 check (discount >= 0),
  total             integer not null default 0 check (total >= 0),

  payment_method    payment_method not null default 'cash',
  payment_status    payment_status not null default 'pending',
  payment_ref       text,                 -- référence Nita

  scheduled_for     timestamptz,          -- null = immédiat
  note              text,
  proof_photo_path  text,                 -- preuve de livraison (Storage)
  cancelled_reason  text,

  placed_at         timestamptz not null default now(),
  delivered_at      timestamptz,
  updated_at        timestamptz not null default now(),

  constraint orders_client_idem unique (user_id, client_order_id),
  constraint orders_delivery_needs_merchant
    check (type <> 'delivery' or merchant_id is not null)
);

drop trigger if exists trg_orders_updated on orders;
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();

create index if not exists idx_orders_user     on orders(user_id, placed_at desc);
create index if not exists idx_orders_merchant on orders(merchant_id, status);
create index if not exists idx_orders_driver   on orders(driver_id, status);
create index if not exists idx_orders_dispatch on orders(status, zone_id)
  where status in ('ready', 'confirmed');
create index if not exists idx_orders_dropoff  on orders using gist(dropoff_location);

-- FK différées sur driver_locations / driver_cash_ledger
alter table driver_locations
  drop constraint if exists driver_locations_order_fk,
  add constraint driver_locations_order_fk
  foreign key (order_id) references orders(id) on delete set null;

alter table driver_cash_ledger
  drop constraint if exists driver_cash_ledger_order_fk,
  add constraint driver_cash_ledger_order_fk
  foreign key (order_id) references orders(id) on delete set null;

-- Détail spécifique au service Coursier (colis A → B, sans catalogue).
create table if not exists courier_details (
  order_id         uuid primary key references orders(id) on delete cascade,
  pickup_hint      text not null,
  pickup_location  geography(point, 4326) not null,
  pickup_contact   text,
  dropoff_contact  text,
  parcel           parcel_size not null default 'small',
  parcel_note      text,
  distance_m       integer
);

-- Lignes de commande : tout est figé à la commande. Le catalogue bouge,
-- pas l'historique.
create table if not exists order_items (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null references orders(id) on delete cascade,
  product_id        uuid references products(id) on delete set null,
  product_name      text not null,        -- snapshot
  unit_price        integer not null,     -- snapshot
  quantity          integer not null check (quantity > 0),
  selections        jsonb not null default '[]'::jsonb,
  selections_label  text not null default '',  -- « Portion moyenne · Sauce arachide »
  line_total        integer not null
);

create index if not exists idx_order_items_order on order_items(order_id);

create table if not exists order_status_history (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete cascade,
  status      order_status not null,
  actor_id    uuid references profiles(id) on delete set null,
  note        text,
  created_at  timestamptz not null default now()
);

create index if not exists idx_status_history_order
  on order_status_history(order_id, created_at);

-- Deux triggers et non un seul, pour une raison précise : l'écriture de
-- l'historique doit se faire APRÈS l'insertion. En BEFORE INSERT, la ligne
-- de orders n'existe pas encore, et la clé étrangère
-- order_status_history.order_id → orders.id échouerait à chaque commande.
--
-- Le renseignement de delivered_at, lui, doit se faire AVANT, puisqu'il
-- modifie la ligne en cours d'écriture.

create or replace function public.set_delivered_at()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.status = 'delivered' and new.delivered_at is null then
    new.delivered_at = now();
  end if;
  return new;
end; $$;

create or replace function public.log_order_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (order_id, status, actor_id)
    values (new.id, new.status, auth.uid());
  end if;
  return null;   -- trigger AFTER : la valeur de retour est ignorée
end; $$;

drop trigger if exists trg_set_delivered_at on orders;
create trigger trg_set_delivered_at
  before update of status on orders
  for each row execute function set_delivered_at();

drop trigger if exists trg_log_order_status on orders;
create trigger trg_log_order_status
  after insert or update of status on orders
  for each row execute function log_order_status();

create table if not exists reviews (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete cascade,
  user_id     uuid not null references profiles(id) on delete cascade,
  merchant_id uuid references merchants(id) on delete cascade,
  driver_id   uuid references driver_profiles(id) on delete cascade,
  rating      integer not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now(),
  unique (order_id, user_id)
);

-- =====================================================================
-- 9. FONCTIONS RPC
-- =====================================================================

-- Recherche vectorielle. Utilisée aussi bien par rechercher_produits que
-- par rechercher_par_image (Vision → description → embedding texte).
create or replace function public.match_products(
  query_embedding  vector(1536),
  match_count      integer default 8,
  min_similarity   float   default 0.35,
  filter_category  uuid    default null,
  filter_merchant  uuid    default null,
  origin_lat       double precision default null,
  origin_lng       double precision default null,
  radius_m         integer default null
)
returns table (
  id            uuid,
  merchant_id   uuid,
  merchant_name text,
  name          text,
  description   text,
  image_url     text,
  price         integer,
  is_available  boolean,
  distance_m    integer,
  similarity    float
)
language sql stable security invoker set search_path = public as $$
  select
    p.id,
    p.merchant_id,
    m.name,
    p.name,
    p.description,
    p.image_url,
    p.price,
    p.is_available,
    case when origin_lat is null then null
         else st_distance(
           m.location,
           st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography
         )::integer
    end,
    1 - (p.embedding <=> query_embedding)
  from products p
  join merchants m on m.id = p.merchant_id
  where p.embedding is not null
    and m.is_approved = true
    and (filter_category is null or p.category_id = filter_category)
    and (filter_merchant is null or p.merchant_id = filter_merchant)
    and (radius_m is null or origin_lat is null or st_dwithin(
          m.location, st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography, radius_m))
    and 1 - (p.embedding <=> query_embedding) >= min_similarity
  order by p.embedding <=> query_embedding
  limit least(match_count, 20);
$$;

-- Boutiques proches. Retourne au plus 8 lignes : l'IA ne reçoit jamais
-- le catalogue entier.
create or replace function public.nearby_merchants(
  origin_lat   double precision,
  origin_lng   double precision,
  radius_m     integer default 5000,
  filter_category uuid default null,
  match_count  integer default 8
)
returns table (
  id           uuid,
  name         text,
  description  text,
  logo_url     text,
  address_hint text,
  is_open      boolean,
  rating       numeric,
  prep_time_min integer,
  distance_m   integer
)
language sql stable security invoker set search_path = public as $$
  select
    m.id, m.name, m.description, m.logo_url, m.address_hint,
    m.is_open, m.rating, m.prep_time_min,
    st_distance(m.location, st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography)::integer
  from merchants m
  where m.is_approved = true
    and st_dwithin(m.location, st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography, radius_m)
    and (filter_category is null or m.category_id = filter_category)
  order by m.location <-> st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography
  limit least(match_count, 20);
$$;

-- Comparateur hybride : boutiques partenaires (commandables) puis
-- offres externes (consultables seulement).
create or replace function public.compare_prices(
  query_embedding vector(1536),
  origin_lat      double precision,
  origin_lng      double precision,
  radius_m        integer default 8000,
  match_count     integer default 6
)
returns table (
  source_kind   text,       -- 'partner' | 'external'
  ref_id        uuid,
  seller_name   text,
  product_name  text,
  image_url     text,
  price         integer,
  distance_m    integer,
  in_stock      boolean,
  is_orderable  boolean,
  source_url    text,
  similarity    float
)
language sql stable security invoker set search_path = public as $$
  (
    select
      'partner'::text, p.id, m.name, p.name, p.image_url, p.price,
      st_distance(m.location, st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography)::integer,
      p.is_available, true, null::text,
      1 - (p.embedding <=> query_embedding)
    from products p
    join merchants m on m.id = p.merchant_id
    where p.embedding is not null
      and m.is_approved = true
      and st_dwithin(m.location, st_setsrid(st_point(origin_lng, origin_lat), 4326)::geography, radius_m)
      and 1 - (p.embedding <=> query_embedding) >= 0.4
    order by p.embedding <=> query_embedding
    limit match_count
  )
  union all
  (
    select
      'external'::text, e.id, e.source, e.title, e.image_url, e.price,
      null::integer, e.in_stock, false, e.source_url,
      1 - (e.embedding <=> query_embedding)
    from external_offers e
    where e.embedding is not null
      and e.expires_at > now()
      and 1 - (e.embedding <=> query_embedding) >= 0.4
    order by e.embedding <=> query_embedding
    limit match_count
  );
$$;

-- Solde cash du jour pour l'app livreur.
create or replace function public.driver_daily_balance(target_driver uuid default null)
returns table (collected integer, settled integer, balance integer)
language sql stable security invoker set search_path = public as $$
  select
    coalesce(sum(amount) filter (where amount > 0), 0)::integer,
    coalesce(abs(sum(amount) filter (where amount < 0)), 0)::integer,
    coalesce(sum(amount), 0)::integer
  from driver_cash_ledger
  where driver_id = coalesce(target_driver, auth.uid())
    and created_at >= date_trunc('day', now());
$$;

-- ---------------------------------------------------------------------
-- Fonctions d'accès pour la RLS
-- ---------------------------------------------------------------------
-- Une policy ne doit JAMAIS interroger directement une table qui porte
-- elle-même des policies : si les deux se référencent, Postgres part en
-- récursion infinie et toute lecture échoue. Ces fonctions SECURITY
-- DEFINER lisent sans déclencher d'évaluation de policy, et cassent le
-- cycle — même mécanisme que my_role().

create or replace function public.my_zone()
returns uuid language sql stable security definer set search_path = public as $$
  select zone_id from public.driver_profiles where id = auth.uid()
$$;

create or replace function public.owns_order(target_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.orders o
    where o.id = target_order and o.user_id = auth.uid()
  )
$$;

-- Sert au suivi live : une fois la commande livrée, le client cesse de
-- voir la position et le profil du livreur.
create or replace function public.owns_active_order(target_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.orders o
    where o.id = target_order
      and o.user_id = auth.uid()
      and o.status not in ('delivered', 'cancelled')
  )
$$;

create or replace function public.is_my_active_driver(target_driver uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.orders o
    where o.driver_id = target_driver
      and o.user_id = auth.uid()
      and o.status not in ('delivered', 'cancelled')
  )
$$;

create or replace function public.owns_merchant(target_merchant uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.merchants m
    where m.id = target_merchant and m.owner_id = auth.uid()
  )
$$;

-- Client, livreur assigné, boutiquier concerné, ou admin.
create or replace function public.can_see_order(target_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.orders o
    left join public.merchants m on m.id = o.merchant_id
    where o.id = target_order
      and (o.user_id = auth.uid()
           or o.driver_id = auth.uid()
           or m.owner_id = auth.uid())
  )
$$;

-- L'inscription d'une boutique est libre ; son approbation ne l'est pas.
-- Sans ce garde-fou, un client s'inscrit une boutique avec
-- is_approved = true et apparaît au catalogue public dans la seconde.
create or replace function public.guard_merchant_approval()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      new.is_approved := false;
    elsif new.is_approved is distinct from old.is_approved then
      new.is_approved := old.is_approved;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_guard_merchant_approval on merchants;
create trigger trg_guard_merchant_approval
  before insert or update on merchants
  for each row execute function guard_merchant_approval();

-- =====================================================================
-- 10. ROW LEVEL SECURITY
-- =====================================================================
-- Le backend exécute TOUJOURS les outils IA avec le JWT de l'utilisateur.
-- La service_role key est réservée aux jobs (dispatch, embeddings, ETL).
-- Si un outil tourne en service_role, la RLS ne protège plus rien et le
-- LLM devient un canal d'exfiltration.

alter table profiles              enable row level security;
alter table addresses             enable row level security;
alter table delivery_zones        enable row level security;
alter table driver_profiles       enable row level security;
alter table driver_locations      enable row level security;
alter table driver_cash_ledger    enable row level security;
alter table categories            enable row level security;
alter table merchants             enable row level security;
alter table products              enable row level security;
alter table product_options       enable row level security;
alter table product_option_values enable row level security;
alter table external_offers       enable row level security;
alter table conversations         enable row level security;
alter table messages              enable row level security;
alter table carts                 enable row level security;
alter table cart_items            enable row level security;
alter table orders                enable row level security;
alter table courier_details       enable row level security;
alter table order_items           enable row level security;
alter table order_status_history  enable row level security;
alter table reviews               enable row level security;

-- Postgres n'a pas de CREATE POLICY IF NOT EXISTS : rejouer le script
-- échouerait sur la première policy déjà présente. On repart donc d'une
-- ardoise propre sur nos tables — et sur nos tables seulement.
do $$
declare
  pol record;
begin
  for pol in
    select policyname, tablename
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'profiles', 'addresses', 'delivery_zones', 'driver_profiles',
        'driver_locations', 'driver_cash_ledger', 'categories', 'merchants',
        'products', 'product_options', 'product_option_values',
        'external_offers', 'conversations', 'messages', 'carts', 'cart_items',
        'orders', 'courier_details', 'order_items', 'order_status_history',
        'reviews'
      )
  loop
    execute format('drop policy if exists %I on public.%I', pol.policyname, pol.tablename);
  end loop;
end $$;

-- ---- profiles -------------------------------------------------------
create policy profiles_self_read on profiles for select
  using (id = auth.uid() or is_admin());
create policy profiles_self_write on profiles for update
  using (id = auth.uid() or is_admin())
  with check (id = auth.uid() or is_admin());
create policy profiles_admin_all on profiles for all
  using (is_admin()) with check (is_admin());

-- ---- addresses ------------------------------------------------------
create policy addresses_owner on addresses for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- ---- catalogue : lecture publique, écriture réservée -----------------
create policy zones_read      on delivery_zones for select using (true);
create policy categories_read on categories     for select using (is_active or is_admin());
create policy merchants_read  on merchants      for select using (is_approved or owner_id = auth.uid() or is_admin());
create policy products_read   on products       for select
  using (exists (select 1 from merchants m where m.id = merchant_id
                 and (m.is_approved or m.owner_id = auth.uid())) or is_admin());
create policy options_read    on product_options for select
  using (exists (select 1 from products p where p.id = product_id));
create policy values_read     on product_option_values for select
  using (exists (select 1 from product_options o where o.id = option_id));
create policy external_read   on external_offers for select using (true);

create policy merchants_owner_write on merchants for all
  using (owner_id = auth.uid() or is_admin())
  with check (owner_id = auth.uid() or is_admin());

create policy products_owner_write on products for all
  using (exists (select 1 from merchants m where m.id = merchant_id and m.owner_id = auth.uid()) or is_admin())
  with check (exists (select 1 from merchants m where m.id = merchant_id and m.owner_id = auth.uid()) or is_admin());

create policy options_owner_write on product_options for all
  using (exists (select 1 from products p join merchants m on m.id = p.merchant_id
                 where p.id = product_id and m.owner_id = auth.uid()) or is_admin())
  with check (exists (select 1 from products p join merchants m on m.id = p.merchant_id
                 where p.id = product_id and m.owner_id = auth.uid()) or is_admin());

create policy values_owner_write on product_option_values for all
  using (exists (select 1 from product_options o join products p on p.id = o.product_id
                 join merchants m on m.id = p.merchant_id
                 where o.id = option_id and m.owner_id = auth.uid()) or is_admin())
  with check (exists (select 1 from product_options o join products p on p.id = o.product_id
                 join merchants m on m.id = p.merchant_id
                 where o.id = option_id and m.owner_id = auth.uid()) or is_admin());

create policy zones_admin_write      on delivery_zones for all using (is_admin()) with check (is_admin());
create policy categories_admin_write on categories     for all using (is_admin()) with check (is_admin());
create policy external_admin_write   on external_offers for all using (is_admin()) with check (is_admin());

-- ---- livreurs -------------------------------------------------------
-- Le client ne voit QUE le livreur assigné à une de ses commandes en cours.
create policy drivers_self on driver_profiles for all
  using (id = auth.uid() or is_admin())
  with check (id = auth.uid() or is_admin());

create policy drivers_visible_to_customer on driver_profiles for select
  using (is_my_active_driver(id));

create policy driver_locations_self on driver_locations for all
  using (driver_id = auth.uid() or is_admin())
  with check (driver_id = auth.uid());

create policy driver_locations_customer on driver_locations for select
  using (owns_active_order(order_id));

create policy cash_ledger_self on driver_cash_ledger for select
  using (driver_id = auth.uid() or is_admin());
create policy cash_ledger_admin on driver_cash_ledger for all
  using (is_admin()) with check (is_admin());

-- ---- conversation ---------------------------------------------------
create policy conversations_owner on conversations for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

create policy messages_owner on messages for all
  using (exists (select 1 from conversations c where c.id = conversation_id
                 and (c.user_id = auth.uid() or is_admin())))
  with check (exists (select 1 from conversations c where c.id = conversation_id
                 and c.user_id = auth.uid()));

-- ---- panier ---------------------------------------------------------
create policy carts_owner on carts for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

create policy cart_items_owner on cart_items for all
  using (exists (select 1 from carts c where c.id = cart_id and c.user_id = auth.uid()))
  with check (exists (select 1 from carts c where c.id = cart_id and c.user_id = auth.uid()));

-- ---- commandes ------------------------------------------------------
create policy orders_client on orders for select
  using (user_id = auth.uid() or is_admin());

create policy orders_client_insert on orders for insert
  with check (user_id = auth.uid());

create policy orders_merchant on orders for select
  using (owns_merchant(merchant_id));

create policy orders_merchant_update on orders for update
  using (owns_merchant(merchant_id))
  with check (owns_merchant(merchant_id));

-- Un livreur voit ses courses, plus le pool ouvert de sa zone.
create policy orders_driver on orders for select
  using (
    driver_id = auth.uid()
    or (
      my_role() = 'driver'
      and driver_id is null
      and status = 'ready'
      and zone_id = my_zone()
    )
  );

-- L'acceptation est restreinte à la zone : sans cette condition, n'importe
-- quel livreur pouvait prendre n'importe quelle course de la ville.
create policy orders_driver_update on orders for update
  using (
    driver_id = auth.uid()
    or (
      my_role() = 'driver'
      and driver_id is null
      and status = 'ready'
      and zone_id = my_zone()
    )
  )
  with check (driver_id = auth.uid());

create policy orders_admin on orders for all using (is_admin()) with check (is_admin());

-- can_see_order() et non « la commande existe » : la version naïve
-- (exists select 1 from orders where id = order_id) rend le contenu de
-- toute commande lisible par n'importe quel utilisateur authentifié.
create policy courier_details_read on courier_details for select
  using (can_see_order(order_id));
create policy courier_details_insert on courier_details for insert
  with check (owns_order(order_id));

create policy order_items_read on order_items for select
  using (can_see_order(order_id));
create policy order_items_insert on order_items for insert
  with check (owns_order(order_id));

create policy status_history_read on order_status_history for select
  using (can_see_order(order_id));

create policy reviews_owner on reviews for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());
create policy reviews_public_read on reviews for select using (true);

-- =====================================================================
-- 11. REALTIME
-- =====================================================================
-- Les policies ci-dessus s'appliquent aussi aux flux Realtime : un client
-- abonné à driver_locations ne reçoit que les pings du livreur de SA
-- commande en cours.

-- Ajouter une table déjà publiée lève une erreur : on vérifie d'abord, pour
-- que le script reste rejouable.
do $$
declare
  t text;
begin
  foreach t in array array[
    'orders', 'order_status_history', 'messages', 'driver_locations', 'cart_items'
  ]
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Payload complet sur update, pour que le client reçoive l'ancien statut.
alter table orders               replica identity full;
alter table order_status_history replica identity full;
alter table driver_locations     replica identity full;
