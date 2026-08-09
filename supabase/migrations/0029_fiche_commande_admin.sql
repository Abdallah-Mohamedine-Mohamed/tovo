-- =====================================================================
-- 0029 — La fiche complète d'une commande, pour l'administration
-- =====================================================================
-- L'admin voyait une ligne de tableau : un total, un repère, un statut. Quand
-- un client appelle pour se plaindre, ça ne suffit pas — il faut son numéro,
-- ce qu'il a commandé, depuis combien de temps il attend, quel livreur a pris
-- la course et à quelle heure.
--
-- Tout existait déjà en base, éparpillé dans six tables. Cette fonction le
-- rassemble en un seul aller-retour : ouvrir une fiche ne doit pas déclencher
-- six requêtes depuis un navigateur, surtout sur un réseau lent.

create or replace function public.admin_order_detail(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when o.id is null then null else jsonb_build_object(
    'id',               o.id,
    'type',             o.type,
    'status',           o.status,
    'placed_at',        o.placed_at,
    'delivered_at',     o.delivered_at,
    -- Le temps d'attente est ce que l'admin regarde en premier : une
    -- commande de quarante minutes en « en attente » est un incident.
    'attente_min',      (extract(epoch from (now() - o.placed_at)) / 60)::integer,
    'note',             o.note,
    'cancelled_reason', o.cancelled_reason,

    'items_total',      o.items_total,
    'delivery_fee',     o.delivery_fee,
    'discount',         o.discount,
    'total',            o.total,
    'commission_amount', o.commission_amount,
    'merchant_payout',  o.merchant_payout,
    'driver_earning',   o.driver_earning,

    'payment_method',   o.payment_method,
    'payment_status',   o.payment_status,
    'payment_ref',      o.payment_ref,
    'payment_confirmed_at', o.payment_confirmed_at,
    -- Qui a déclaré l'encaissement : nul quand c'est Nita qui l'a constaté.
    'payment_confirmed_by', (
      select p.full_name from profiles p where p.id = o.payment_confirmed_by
    ),

    'client', (
      select jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.user_id
    ),
    'merchant', case when o.merchant_id is null then null else (
      select jsonb_build_object(
        'id', m.id, 'name', m.name, 'phone', m.phone,
        'address_hint', m.address_hint,
        'is_open', public.merchant_open_now(m.id)
      )
      from merchants m where m.id = o.merchant_id
    ) end,
    'driver', case when o.driver_id is null then null else (
      select jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.driver_id
    ) end,

    'dropoff', jsonb_build_object(
      'hint', o.dropoff_hint,
      'lat',  st_y(o.dropoff_location::geometry),
      'lng',  st_x(o.dropoff_location::geometry)
    ),
    'pickup', (
      select jsonb_build_object(
        'hint', cd.pickup_hint,
        'lat',  st_y(cd.pickup_location::geometry),
        'lng',  st_x(cd.pickup_location::geometry)
      )
      from courier_details cd where cd.order_id = o.id
    ),

    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',       p.name,
        'quantity',   oi.quantity,
        'unit_price', oi.unit_price,
        'line_total', oi.unit_price * oi.quantity,
        -- Le libellé est figé sur la ligne de commande, pas recalculé : il
        -- doit rester celui du jour de l'achat même si le boutiquier renomme
        -- ses options ensuite.
        'options',    oi.selections_label
      ) order by oi.id)
      from order_items oi
      join products p on p.id = oi.product_id
      where oi.order_id = o.id
    ), '[]'::jsonb),

    -- L'historique dit où le temps a été perdu : trente minutes entre
    -- « prête » et « livreur assigné » désigne un problème de dispatch, pas
    -- une cuisine lente.
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('status', h.status, 'at', h.created_at)
                       order by h.created_at)
      from order_status_history h where h.order_id = o.id
    ), '[]'::jsonb)
  ) end
  from orders o
  where o.id = p_order_id
    and public.is_admin()
$$;

notify pgrst, 'reload schema';
