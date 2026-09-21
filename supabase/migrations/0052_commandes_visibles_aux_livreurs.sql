-- =====================================================================
-- 0052 — Une commande existe avant d'être prête
-- =====================================================================
-- Jusqu'ici, le livreur ne voyait une commande qu'au statut `ready`.
-- Pendant toute la confirmation et la préparation, son écran disait donc
-- « aucune course », alors que la commande existait déjà.
--
-- On sépare désormais deux notions :
--   - visible : pending, confirmed, preparing ou ready ;
--   - prenable : ready seulement.
--
-- Le livreur peut ainsi anticiper sans réserver une commande que la
-- boutique pourrait encore refuser. Les colis planifiés restent cachés
-- jusqu'à leur heure de départ.

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
  can_accept     boolean
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
    o.status = 'ready'
  from orders o
  left join merchants m on m.id = o.merchant_id
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

-- Un livreur voit ses courses et les commandes à venir de sa zone.
--
-- Une zone n'est pas obligatoire sur le profil. Le dispatch automatique
-- traitait déjà un livreur sans zone comme disponible dans toute la ville,
-- alors que la RLS lui cachait tout le pool : deux règles contradictoires.
-- Un profil sans zone voit désormais toutes les zones ; une commande hors
-- zone reste également visible afin de ne jamais devenir orpheline.
drop policy if exists orders_driver on orders;
create policy orders_driver on orders for select
  using (
    driver_id = auth.uid()
    or (
      my_role() = 'driver'
      and driver_id is null
      and status in ('pending', 'confirmed', 'preparing', 'ready')
      and (
        my_zone() is null
        or zone_id is null
        or zone_id = my_zone()
      )
    )
  );

notify pgrst, 'reload schema';
