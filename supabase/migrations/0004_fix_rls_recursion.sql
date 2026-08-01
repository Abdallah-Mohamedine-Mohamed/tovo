-- =====================================================================
-- 0004 — Correction des policies : récursion, approbation, portée
-- =====================================================================
-- Trois problèmes révélés par les tests RLS.
--
-- 1. RÉCURSION INFINIE
--    orders_driver interroge driver_profiles, dont la policy
--    drivers_visible_to_customer interroge orders. Toute lecture de orders,
--    driver_profiles ou driver_locations échouait.
--    Correction : les policies ne traversent plus les tables entre elles.
--    Elles appellent des fonctions SECURITY DEFINER, qui lisent sans
--    déclencher d'évaluation de policy — le même mécanisme que my_role().
--
-- 2. AUTO-APPROBATION DES BOUTIQUES
--    Un client pouvait s'inscrire une boutique avec is_approved = true et
--    apparaître immédiatement au catalogue public.
--    Correction : is_approved n'est modifiable que par un admin.
--
-- 3. PORTÉE TROP LARGE
--    order_items, order_status_history et courier_details testaient
--    l'EXISTENCE de la commande, pas l'appartenance. N'importe quel
--    utilisateur authentifié lisait le contenu de n'importe quelle commande.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Fonctions d'accès — briseuses de cycle
-- ---------------------------------------------------------------------

-- Zone du livreur courant.
create or replace function public.my_zone()
returns uuid language sql stable security definer set search_path = public as $$
  select zone_id from public.driver_profiles where id = auth.uid()
$$;

-- Cette commande m'appartient-elle ?
create or replace function public.owns_order(target_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.orders o
    where o.id = target_order and o.user_id = auth.uid()
  )
$$;

-- M'appartient-elle ET est-elle encore en cours ?
-- Sert au suivi live : une fois livrée, le client cesse de voir le livreur.
create or replace function public.owns_active_order(target_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.orders o
    where o.id = target_order
      and o.user_id = auth.uid()
      and o.status not in ('delivered', 'cancelled')
  )
$$;

-- Ce livreur est-il celui d'une de mes commandes en cours ?
create or replace function public.is_my_active_driver(target_driver uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.orders o
    where o.driver_id = target_driver
      and o.user_id = auth.uid()
      and o.status not in ('delivered', 'cancelled')
  )
$$;

-- Suis-je propriétaire de cette boutique ?
create or replace function public.owns_merchant(target_merchant uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.merchants m
    where m.id = target_merchant and m.owner_id = auth.uid()
  )
$$;

-- Ai-je le droit de voir cette commande, à quelque titre que ce soit ?
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

-- ---------------------------------------------------------------------
-- Policies reconstruites
-- ---------------------------------------------------------------------

-- orders ---------------------------------------------------------------
drop policy if exists orders_client          on orders;
drop policy if exists orders_client_insert   on orders;
drop policy if exists orders_merchant        on orders;
drop policy if exists orders_merchant_update on orders;
drop policy if exists orders_driver          on orders;
drop policy if exists orders_driver_update   on orders;
drop policy if exists orders_admin           on orders;

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

-- L'acceptation d'une course est restreinte à la zone du livreur : sans
-- cette condition, n'importe quel livreur pouvait prendre n'importe quelle
-- course, y compris à l'autre bout de la ville.
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

create policy orders_admin on orders for all
  using (is_admin()) with check (is_admin());

-- driver_profiles ------------------------------------------------------
drop policy if exists drivers_visible_to_customer on driver_profiles;

create policy drivers_visible_to_customer on driver_profiles for select
  using (is_my_active_driver(id));

-- driver_locations -----------------------------------------------------
drop policy if exists driver_locations_customer on driver_locations;

create policy driver_locations_customer on driver_locations for select
  using (owns_active_order(order_id));

-- order_items ----------------------------------------------------------
drop policy if exists order_items_via_order on order_items;
drop policy if exists order_items_insert    on order_items;

create policy order_items_read on order_items for select
  using (can_see_order(order_id));

create policy order_items_insert on order_items for insert
  with check (owns_order(order_id));

-- order_status_history -------------------------------------------------
drop policy if exists status_history_via_order on order_status_history;

create policy status_history_read on order_status_history for select
  using (can_see_order(order_id));

-- courier_details ------------------------------------------------------
drop policy if exists courier_details_via_order on courier_details;

create policy courier_details_read on courier_details for select
  using (can_see_order(order_id));

create policy courier_details_insert on courier_details for insert
  with check (owns_order(order_id));

-- ---------------------------------------------------------------------
-- Approbation des boutiques
-- ---------------------------------------------------------------------
-- L'inscription d'une boutique reste libre — c'est l'approbation qui ne
-- l'est pas. On force la valeur au lieu de lever une exception : le
-- boutiquier crée sa fiche, elle attend simplement la validation.

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
