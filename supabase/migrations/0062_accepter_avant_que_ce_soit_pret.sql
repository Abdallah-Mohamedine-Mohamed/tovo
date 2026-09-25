-- ============================================================================
-- 0062 — Un livreur peut accepter une commande de boutique avant qu'elle
--        soit prête
--
-- Jusqu'ici, une commande de boutique n'était acceptable qu'au statut
-- « ready ». Le livreur la voyait dans le pool (« En préparation »), sans
-- pouvoir la prendre : il attendait, ou partait sur une autre course, et le
-- client attendait un livreur APRÈS la cuisine. Le client l'a demandé
-- (25/09) : on accepte dès que la boutique a confirmé, et on file vers elle
-- pendant la préparation.
--
-- Déroulé :
--   1. le livreur accepte une commande confirmée ou en préparation : il y est
--      rattaché (driver_id), le statut ne bouge pas ;
--   2. la boutique la marque « prête » : comme un livreur est déjà dessus,
--      elle passe directement à « assigned » ;
--   3. la suite est inchangée : récupérée, en route, livrée.
-- Une commande « prête » acceptée passe à « assigned », comme avant.
-- ============================================================================

-- 1. L'acceptation. SECURITY DEFINER : la RLS de mise à jour des livreurs
--    ne couvre que les commandes « ready » ; les contrôles sont donc faits
--    ici, explicitement.
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
     and (public.my_zone() is null or zone_id is null or zone_id = public.my_zone());

  get diagnostics claimed = row_count;

  if claimed = 1 then
    update driver_profiles set is_available = false where id = auth.uid();
    return true;
  end if;

  return false;
end; $$;

-- 2. « Prête » avec un livreur déjà dessus : directement « assigned ».
create or replace function public.advance_order_status(
  p_order_id uuid,
  p_status   order_status,
  p_note     text default null
)
returns order_status
language plpgsql security invoker set search_path = public as $$
declare
  v_touched integer;
  v_final   order_status := p_status;
begin
  update orders
     set status = case
       when p_status = 'ready' and driver_id is not null then 'assigned'::order_status
       else p_status
     end
   where id = p_order_id
  returning status into v_final;
  get diagnostics v_touched = row_count;

  if v_touched = 0 then
    raise exception 'commande introuvable' using errcode = 'P0002';
  end if;

  if p_note is not null then
    update order_status_history
       set note = p_note
     where id = (
       select h.id from order_status_history h
       where h.order_id = p_order_id and h.status = v_final
       order by h.created_at desc
       limit 1
     );
  end if;

  return v_final;
end; $$;

-- 3. Le garde-fou des transitions (0051), qui laisse désormais la boutique
--    passer de « confirmée » ou « en préparation » à « assigned » — SEULEMENT
--    si un livreur est déjà rattaché.
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
    if not v_ok and old.driver_id is not null then
      v_ok := v_key = any (array['confirmed>assigned', 'preparing>assigned']);
    end if;
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

-- 4. Le pool : « acceptable » dès la confirmation de la boutique. Même
--    forme que 0060 (mode, départ, distance).
drop function if exists public.driver_pool();

create function public.driver_pool()
returns table (
  id             uuid,
  type           order_type,
  status         order_status,
  total          integer,
  driver_earning integer,
  dropoff_hint   text,
  placed_at      timestamptz,
  merchant_id    uuid,
  merchant_name  text,
  attente_min    integer,
  can_accept     boolean,
  mode           text,
  pickup_hint    text,
  distance_m     integer
)
language sql stable security invoker set search_path = public as $$
  select
    o.id,
    o.type,
    o.status,
    o.total,
    o.driver_earning,
    o.dropoff_hint,
    o.placed_at,
    o.merchant_id,
    m.name,
    (extract(epoch from (now() - o.placed_at)) / 60)::integer,
    o.status in ('confirmed', 'preparing', 'ready'),
    cd.mode,
    cd.pickup_hint,
    st_distance(
      (select dp.current_location from driver_profiles dp where dp.id = auth.uid()),
      coalesce(cd.pickup_location, m.location)
    )::integer
  from orders o
  left join merchants m        on m.id = o.merchant_id
  left join courier_details cd on cd.order_id = o.id
  where o.status in ('pending', 'confirmed', 'preparing', 'ready')
    and o.driver_id is null
    and (o.scheduled_for is null or o.scheduled_for <= now())
    and o.placed_at > now() - make_interval(
      mins => (select order_stale_after_min from platform_settings)
    )
  order by
    -- Prêtes d'abord, puis en préparation, puis en attente de la boutique.
    case o.status when 'ready' then 0 when 'preparing' then 1 when 'confirmed' then 2 else 3 end,
    o.placed_at asc
  limit 30;
$$;

notify pgrst, 'reload schema';
