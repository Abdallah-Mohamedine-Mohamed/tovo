-- ============================================================================
-- 0060 — Une course proposée qui dit où aller, et à quelle distance
--
-- Dans l'appli livreur, une course de colis proposée n'affichait que « Colis
-- · À voir avec le client · 700 F » : ni le point de départ, ni la sorte de
-- course (venir chez le client ou aller chercher ailleurs, 0059), ni la
-- distance. Le livreur acceptait à l'aveugle. Même pour un repas, aucune
-- distance : c'est pourtant ce qui le décide.
--
-- Ajouts : mode, pickup_hint (où partir), distance_m (du livreur jusqu'au
-- départ : la boutique pour un repas, le point de prise en charge pour un
-- colis). La distance est nulle si la position du livreur est inconnue.
-- ============================================================================

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
    o.status = 'ready',
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
    -- Les courses déjà prêtes passent avant celles encore en préparation.
    (o.status = 'ready') desc,
    o.placed_at asc
  limit 30;
$$;

notify pgrst, 'reload schema';
