-- =====================================================================
-- 0021 — Une boutique ouvre à ses heures, pas sur un interrupteur
-- =====================================================================
-- Jusqu'ici, `merchants.is_open` était un simple booléen que le boutiquier
-- devait basculer à la main. Personne ne le fait chaque matin et chaque
-- soir : soit la boutique reste affichée ouverte à 3 h du matin, soit elle
-- reste fermée toute la journée parce que le patron a oublié.
--
-- 6ammart tenait déjà 529 horaires pour 76 boutiques, jour par jour, avec de
-- vraies plages : 10 h, 11 h, 12 h, 17 h, 19 h selon les commerces. Cette
-- information existe, il suffit de s'en servir.
--
-- Le modèle retenu garde DEUX niveaux, et la distinction compte :
--
--   `is_open`        — le boutiquier accepte les commandes en ce moment.
--                      C'est son interrupteur, pour fermer un jour de fête
--                      ou quand la cuisine est débordée.
--
--   `merchant_hours` — quand la boutique est censée être ouverte.
--
-- Une boutique est réellement ouverte si les deux le disent. Sans horaire
-- enregistré, seul l'interrupteur compte — c'est le cas d'une boutique qui
-- vient d'arriver et n'a pas encore réglé ses heures.

create table if not exists merchant_hours (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references merchants(id) on delete cascade,
  -- 0 = dimanche, comme le renvoie `extract(dow)` de Postgres et comme le
  -- stockait 6ammart. Aligner les deux évite un décalage d'un jour que
  -- personne ne remarque avant qu'un client ne trouve tout fermé le lundi.
  day         smallint not null check (day between 0 and 6),
  opens_at    time not null,
  closes_at   time not null,
  created_at  timestamptz not null default now()
);

-- Plusieurs plages par jour sont permises — midi et soir, comme beaucoup de
-- restaurants. L'unicité porte donc sur l'horaire entier, pas sur le jour.
create unique index if not exists idx_merchant_hours_unique
  on merchant_hours(merchant_id, day, opens_at, closes_at);
create index if not exists idx_merchant_hours_lookup
  on merchant_hours(merchant_id, day);

alter table merchant_hours enable row level security;

drop policy if exists merchant_hours_read on merchant_hours;
create policy merchant_hours_read on merchant_hours for select using (true);

drop policy if exists merchant_hours_owner on merchant_hours;
create policy merchant_hours_owner on merchant_hours for all
  using (owns_merchant(merchant_id) or is_admin())
  with check (owns_merchant(merchant_id) or is_admin());

/*
 * La boutique est-elle ouverte maintenant ?
 *
 * Le fuseau est explicite et non négociable. La base tourne en UTC, le Niger
 * vit en UTC+1 sans heure d'été : comparer l'heure d'ouverture locale à une
 * horloge UTC décalerait tout d'une heure, et personne ne verrait l'erreur
 * avant qu'un restaurant n'apparaisse fermé à midi.
 */
create or replace function public.merchant_open_now(p_merchant_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  with local as (
    select (now() at time zone 'Africa/Niamey') as maintenant
  )
  select
    coalesce((select m.is_open from merchants m where m.id = p_merchant_id), false)
    and (
      -- Pas d'horaire enregistré : l'interrupteur fait foi. Une boutique
      -- neuve ne doit pas être invisible pour n'avoir rien saisi.
      not exists (select 1 from merchant_hours h where h.merchant_id = p_merchant_id)
      or exists (
        select 1
        from merchant_hours h, local l
        where h.merchant_id = p_merchant_id
          and h.day = extract(dow from l.maintenant)::smallint
          and l.maintenant::time between h.opens_at and h.closes_at
      )
    )
$$;

-- ---------------------------------------------------------------------
-- Ce que voient le panier et les listes
-- ---------------------------------------------------------------------

/*
 * Le panier tient compte des horaires.
 *
 * Sans ça, un client compose son panier à 23 h, voit « Commander », et
 * découvre au paiement que personne ne prépare. Le blocage doit dire la
 * vérité au moment où il la connaît.
 */
create or replace function public.cart_view(
  p_lat double precision default null,
  p_lng double precision default null
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cart     record;
  v_items    jsonb;
  v_items_tot integer := 0;
  v_fee      integer := 0;
  v_blocked  text := null;
begin
  select c.id, c.merchant_id, m.name as merchant_name,
         public.merchant_open_now(c.merchant_id) as is_open
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

/*
 * Les produits d'une catégorie, boutiques réellement ouvertes en tête.
 *
 * Reprend la 0020 en remplaçant `m.is_open` par l'ouverture calculée : un
 * restaurant qui n'ouvre qu'à 19 h ne doit pas passer devant un commerce
 * ouvert à l'instant où le client regarde.
 */
create or replace function public.category_products(
  p_category_id uuid,
  p_limite      integer default 12
)
returns table (
  id            uuid,
  name          text,
  description   text,
  image_url     text,
  price         integer,
  is_available  boolean,
  merchant_id   uuid,
  merchant_name text
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.description, p.image_url, p.price, p.is_available,
         p.merchant_id, m.name
  from products p
  join merchants m on m.id = p.merchant_id
  left join categories enfant on enfant.id = p.category_id
  where p.is_available
    and m.is_approved
    and (p.category_id = p_category_id or enfant.parent_id = p_category_id)
  order by public.merchant_open_now(m.id) desc, p.name
  limit p_limite
$$;

notify pgrst, 'reload schema';
