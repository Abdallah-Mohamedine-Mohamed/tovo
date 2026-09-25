-- ============================================================================
-- 0063 — Un livreur de « Niamey » voit aussi les commandes de Yantala
--
-- Les zones se chevauchent : « Niamey » couvre toute la ville, Yantala,
-- Plateau, Lazaret… en sont des quartiers. Une commande prend la zone LA
-- PLUS FINE de son point de collecte (0008) ; un livreur, lui, est souvent
-- rattaché à la ville entière.
--
-- Toutes les règles comparaient les deux par ÉGALITÉ : un livreur de
-- « Niamey » ne voyait, ne recevait et ne pouvait accepter AUCUNE commande
-- de boutique située dans un quartier. Constaté le 25/09 : une commande chez
-- Maison Grill (Yantala) n'a jamais atteint le seul livreur en ligne
-- (zone Niamey), alors que les colis — dont le départ ne tombait dans aucun
-- quartier — lui arrivaient.
--
-- Désormais : la zone du livreur COUVRE celle de la commande si c'est la
-- même, ou si elle contient ce quartier.
-- ============================================================================

-- 1. Les zones qui couvrent une zone donnée (elle comprise).
--    Un quartier est « dans » une zone quand un point intérieur au quartier
--    s'y trouve : plus tolérant qu'une inclusion stricte des polygones, que
--    des tracés faits à la main ne respectent jamais au mètre près.
create or replace function public.zones_englobantes(p_zone uuid)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select p_zone where p_zone is not null
  union
  select parent.id
  from delivery_zones enfant
  join delivery_zones parent
    on parent.id <> enfant.id
   and st_covers(
         parent.area,
         st_pointonsurface(enfant.area::geometry)::geography
       )
  where enfant.id = p_zone;
$$;

grant execute on function public.zones_englobantes(uuid) to authenticated, service_role;

-- 2. La règle, en une fonction : même sémantique qu'avant pour les zones
--    absentes (un livreur sans zone voit toute la ville ; une commande sans
--    zone reste visible de tous, pour ne jamais devenir orpheline).
create or replace function public.zone_couvre(p_zone_livreur uuid, p_zone_commande uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_zone_livreur is null
      or p_zone_commande is null
      or p_zone_livreur in (select public.zones_englobantes(p_zone_commande));
$$;

grant execute on function public.zone_couvre(uuid, uuid) to authenticated, service_role;

-- 3. Ce que le livreur VOIT (reprend 0052, seule la condition de zone change).
drop policy if exists orders_driver on orders;
create policy orders_driver on orders for select
  using (
    driver_id = auth.uid()
    or (
      my_role() = 'driver'
      and driver_id is null
      and status in ('pending', 'confirmed', 'preparing', 'ready')
      and public.zone_couvre(my_zone(), zone_id)
    )
  );

-- 4. Ce qu'il peut PRENDRE en direct (reprend 0004).
drop policy if exists orders_driver_update on orders;
create policy orders_driver_update on orders for update
  using (
    driver_id = auth.uid()
    or (
      my_role() = 'driver'
      and driver_id is null
      and status = 'ready'
      and public.zone_couvre(my_zone(), zone_id)
    )
  )
  with check (driver_id = auth.uid());

-- 5. L'acceptation (reprend 0062).
create or replace function public.accept_order(target_order uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  claimed integer;
begin
  if auth.uid() is null or public.my_role() <> 'driver' then
    raise exception 'réservé aux livreurs' using errcode = '42501';
  end if;

  update orders
     set driver_id = auth.uid(),
         status    = case when status = 'ready' then 'assigned'::order_status else status end
   where id = target_order
     and driver_id is null
     and status in ('confirmed', 'preparing', 'ready')
     and (scheduled_for is null or scheduled_for <= now())
     and public.zone_couvre(public.my_zone(), zone_id);

  get diagnostics claimed = row_count;

  if claimed = 1 then
    update driver_profiles set is_available = false where id = auth.uid();
    return true;
  end if;

  return false;
end; $$;

-- 6. Les candidats au dispatch (reprend 0007).
create or replace function public.dispatch_candidates(p_order_id uuid)
returns table (
  driver_id  uuid,
  full_name  text,
  fcm_token  text,
  distance_m integer
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_order    record;
  v_origin   geography;
  v_limit    integer;
  v_radius   integer;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'réservé au dispatch' using errcode = '42501';
  end if;

  select o.id, o.zone_id, o.merchant_id, o.type, o.status
    into v_order
  from orders o where o.id = p_order_id;

  if v_order.id is null or v_order.status <> 'ready' then
    return;
  end if;

  select s.dispatch_candidates, s.dispatch_max_radius_m
    into v_limit, v_radius
  from platform_settings s;

  if v_order.type = 'courier' then
    select cd.pickup_location into v_origin
    from courier_details cd where cd.order_id = p_order_id;
  else
    select m.location into v_origin
    from merchants m where m.id = v_order.merchant_id;
  end if;

  if v_origin is null then
    return;
  end if;

  return query
  select
    d.id,
    pr.full_name,
    d.fcm_token,
    st_distance(d.current_location, v_origin)::integer
  from driver_profiles d
  join profiles pr on pr.id = d.id
  where d.is_online
    and d.is_available
    and d.current_location is not null
    and public.zone_couvre(d.zone_id, v_order.zone_id)
    and st_dwithin(d.current_location, v_origin, v_radius)
    and (d.last_seen_at is null or d.last_seen_at > now() - interval '2 minutes')
  order by d.current_location <-> v_origin
  limit greatest(v_limit, 1);
end; $$;

notify pgrst, 'reload schema';
