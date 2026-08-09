-- =====================================================================
-- 0030 — Ce que le livreur doit avoir sous les yeux
-- =====================================================================
-- `order_tracking` avait été écrite pour le CLIENT qui suit sa commande :
-- elle lui donne le nom et le téléphone de son livreur. La même fonction
-- sert au livreur — qui n'y trouvait donc ni le nom ni le numéro du client,
-- ni l'adresse de la boutique, ni ses coordonnées.
--
-- Résultat sur le terrain : un livreur qui ne peut ni appeler le client
-- introuvable, ni faire route vers la boutique. Les positions étaient
-- pourtant enregistrées sur toutes les commandes depuis le premier jour ;
-- rien ne les affichait.
--
-- La fonction passe en SECURITY DEFINER : le livreur n'a pas le droit de
-- lire la fiche `profiles` de son client, et c'est très bien ainsi — il ne
-- doit voir ce numéro QUE pour la course qu'il a acceptée. D'où le contrôle
-- explicite ci-dessous, qui remplace la RLS qu'on vient de contourner.

create or replace function public.order_tracking(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_id',       o.id,
    'type',           o.type,
    'status',         o.status,
    'total',          o.total,
    'items_total',    o.items_total,
    'delivery_fee',   o.delivery_fee,
    'payment_method', o.payment_method,
    'payment_status', o.payment_status,
    'placed_at',      o.placed_at,
    'delivered_at',   o.delivered_at,
    'note',           o.note,
    'merchant_name',  m.name,

    -- LE CLIENT.
    --
    -- Caché à lui-même : le client qui suit sa commande n'a que faire de son
    -- propre numéro, et l'afficher dans sa carte de suivi serait du bruit.
    -- Les autres lecteurs possibles — livreur assigné, boutiquier, admin —
    -- sont précisément ceux qui ont besoin de l'appeler.
    'client', case when o.user_id = auth.uid() then null else (
      select jsonb_build_object('name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.user_id
    ) end,

    -- LA BOUTIQUE, avec de quoi s'y rendre et l'appeler.
    --
    -- Un livreur qui arrive devant une boutique fermée ou introuvable perd
    -- dix minutes et le client attend d'autant.
    'merchant', case when o.merchant_id is null then null else (
      select jsonb_build_object(
        'name',    m2.name,
        'phone',   m2.phone,
        'hint',    m2.address_hint,
        'lat',     st_y(m2.location::geometry),
        'lng',     st_x(m2.location::geometry)
      )
      from merchants m2 where m2.id = o.merchant_id
    ) end,

    'driver', case when o.driver_id is null then null else jsonb_build_object(
      'id',      pr.id,
      'name',    pr.full_name,
      'phone',   pr.phone,
      'vehicle', dp.vehicle_type,
      'rating',  dp.rating
    ) end,
    'dropoff', jsonb_build_object(
      'hint', o.dropoff_hint,
      'lat',  st_y(o.dropoff_location::geometry),
      'lng',  st_x(o.dropoff_location::geometry)
    ),
    'pickup', case when cd.order_id is null then null else jsonb_build_object(
      'hint', cd.pickup_hint,
      'lat',  st_y(cd.pickup_location::geometry),
      'lng',  st_x(cd.pickup_location::geometry)
    ) end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_name',     oi.product_name,
        'selections_label', oi.selections_label,
        'quantity',         oi.quantity,
        'line_total',       oi.line_total
      )) from order_items oi where oi.order_id = o.id
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('status', h.status, 'at', h.created_at)
                       order by h.created_at)
      from order_status_history h where h.order_id = o.id
    ), '[]'::jsonb)
  )
  from orders o
  left join merchants m        on m.id = o.merchant_id
  left join driver_profiles dp on dp.id = o.driver_id
  left join profiles pr        on pr.id = o.driver_id
  left join courier_details cd on cd.order_id = o.id
  where o.id = p_order_id
    -- LA garde de cette fonction. En SECURITY DEFINER, la RLS de `orders` ne
    -- s'applique plus : sans cette ligne, n'importe qui muni d'un
    -- identifiant de commande lirait le nom, le numéro et l'adresse exacte
    -- d'un client qui ne lui a jamais rien demandé.
    and public.can_see_order(o.id);
$$;

notify pgrst, 'reload schema';
