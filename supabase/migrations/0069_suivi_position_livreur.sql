-- La carte de suivi : la dernière position du livreur, dès l'ouverture.
--
-- Le suivi recevait les positions en direct (Realtime, table
-- driver_locations), mais seulement les SUIVANTES : à l'ouverture de l'écran,
-- la moto n'apparaissait qu'au prochain envoi (jusqu'à 10 s). order_tracking
-- donne maintenant la dernière position connue : celle envoyée pour CETTE
-- commande, sinon la position courante du livreur.
--
-- Vie privée : la position n'est donnée que pendant la course. Livrée ou
-- annulée, la commande ne dit plus où se trouve le livreur.
--
-- Même fonction que 0059, avec `driver.position` en plus.

create or replace function public.order_tracking(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_id',       o.id,
    'type',           o.type,
    'mode',           cd.mode,
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

    'client', case when o.user_id = auth.uid() then null else (
      select jsonb_build_object('name', p.full_name, 'phone', p.phone)
      from profiles p where p.id = o.user_id
    ) end,

    'merchant', case when o.merchant_id is null then null else (
      select jsonb_build_object(
        'name',  m2.name,
        'phone', m2.phone,
        'hint',  m2.address_hint,
        'lat',   st_y(m2.location::geometry),
        'lng',   st_x(m2.location::geometry)
      )
      from merchants m2 where m2.id = o.merchant_id
    ) end,

    'driver', case when o.driver_id is null then null else jsonb_build_object(
      'id',      pr.id,
      'name',    pr.full_name,
      'phone',   pr.phone,
      'vehicle', dp.vehicle_type,
      'rating',  dp.rating,
      'position', case when o.status in ('delivered', 'cancelled') then null else coalesce(
        (select jsonb_build_object(
            'lat',     st_y(dl.location::geometry),
            'lng',     st_x(dl.location::geometry),
            'heading', dl.heading,
            'at',      dl.recorded_at)
           from driver_locations dl
          where dl.order_id = o.id
          order by dl.recorded_at desc
          limit 1),
        case when dp.current_location is null then null else jsonb_build_object(
          'lat', st_y(dp.current_location::geometry),
          'lng', st_x(dp.current_location::geometry),
          'heading', null,
          'at', dp.last_seen_at)
        end)
      end
    ) end,

    'dropoff', jsonb_build_object(
      'hint',    o.dropoff_hint,
      'lat',     st_y(o.dropoff_location::geometry),
      'lng',     st_x(o.dropoff_location::geometry),
      'contact', cd.dropoff_contact
    ),
    'pickup', case when cd.order_id is null then null else jsonb_build_object(
      'hint',    cd.pickup_hint,
      'lat',     case when cd.mode = 'recuperer' then null else st_y(cd.pickup_location::geometry) end,
      'lng',     case when cd.mode = 'recuperer' then null else st_x(cd.pickup_location::geometry) end,
      'contact', cd.pickup_contact
    ) end,
    'parcel',      cd.parcel,
    'parcel_note', cd.parcel_note,

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
    and public.can_see_order(o.id);
$$;

-- Le suivi rafraîchit l'app sans attendre : on relit la fonction.
notify pgrst, 'reload schema';
