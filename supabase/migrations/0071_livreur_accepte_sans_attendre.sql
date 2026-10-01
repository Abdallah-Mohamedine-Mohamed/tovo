-- ============================================================================
-- 0071 — Le livreur prend une commande de boutique sans attendre la boutique,
--        et la course se fait en deux gestes
--
-- Jusqu'ici, une commande de boutique n'était acceptable qu'une fois
-- CONFIRMÉE par la boutique (0062). Or la plupart des boutiques n'ont pas
-- encore l'app en main : la commande restait « en attente » pour toujours,
-- aucun livreur ne pouvait la prendre (constaté le 28/09 : O'TAKOSS). Le
-- client l'a tranché (29/09) : le livreur l'accepte tout de suite, va à la
-- boutique, passe la commande sur place et la récupère.
--
-- Et le moins d'étapes possible pour le livreur, sinon elles ne seront pas
-- faites :
--   1. il ACCEPTE (en attente, confirmée, en préparation ou prête) ;
--   2. « Commande récupérée » → « delivering » (plus d'étape « en route » :
--      récupérer, c'est partir livrer) ;
--   3. « Commande livrée » → « delivered ».
--
-- Côté boutique, « confirmée » et « en préparation » ne font qu'une : elle
-- peut passer d'« en attente » à « en préparation » (ou « prête »)
-- directement.
--
-- Une boutique qui a l'app garde la main : elle peut encore confirmer,
-- préparer, marquer prête, ou refuser (annuler) — un livreur déjà dessus
-- voit alors la commande annulée.
-- ============================================================================

-- 1. L'acceptation : dès la commande passée.
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
     and status in ('pending', 'confirmed', 'preparing', 'ready')
     and (scheduled_for is null or scheduled_for <= now())
     and public.zone_couvre(public.my_zone(), zone_id);

  get diagnostics claimed = row_count;

  if claimed = 1 then
    update driver_profiles set is_available = false where id = auth.uid();
    return true;
  end if;

  return false;
end; $$;

-- 2. Les transitions permises.
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

  -- La boutique : confirmer / préparer (une seule étape), marquer prête,
  -- refuser.
  if public.owns_merchant(old.merchant_id) then
    v_ok := v_key = any (array[
      'pending>confirmed',
      'pending>preparing',
      'pending>ready',
      'confirmed>preparing',
      'confirmed>ready',
      'preparing>ready',
      'pending>cancelled',
      'confirmed>cancelled',
      'preparing>cancelled'
    ]);
    -- « Prête » avec un livreur déjà dessus : directement « assigned ».
    if not v_ok and old.driver_id is not null then
      v_ok := v_key = any (array['pending>assigned', 'confirmed>assigned', 'preparing>assigned']);
    end if;
  end if;

  -- Le livreur qui accepte une commande prête (accept_order).
  if not v_ok
     and old.driver_id is null
     and new.driver_id = auth.uid()
     and v_key = 'ready>assigned'
     and public.my_role() = 'driver' then
    v_ok := true;
  end if;

  -- Le livreur de la course : « récupérée » depuis n'importe quel état
  -- d'avant (il a la commande en main, que la boutique ait suivi dans l'app
  -- ou non), puis « livrée ». Les anciennes étapes restent permises pour
  -- les apps livreur pas encore mises à jour.
  if not v_ok and old.driver_id = auth.uid() then
    v_ok := v_key = any (array[
      'pending>delivering',
      'confirmed>delivering',
      'preparing>delivering',
      'ready>delivering',
      'assigned>delivering',
      'assigned>picked_up',
      'picked_up>delivering',
      'picked_up>delivered',
      'delivering>delivered'
    ]);
  end if;

  -- Le client : annuler tant qu'aucun livreur n'est dessus.
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

-- 3. Le pool : tout est acceptable dès la commande passée. Même forme que
--    0062.
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
    o.status in ('pending', 'confirmed', 'preparing', 'ready'),
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
    -- Prêtes d'abord, puis en préparation, puis les plus anciennes.
    case o.status when 'ready' then 0 when 'preparing' then 1 when 'confirmed' then 2 else 3 end,
    o.placed_at asc
  limit 30;
$$;

notify pgrst, 'reload schema';
