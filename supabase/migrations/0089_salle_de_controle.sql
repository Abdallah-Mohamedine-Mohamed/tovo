-- =====================================================================
-- 0089 — La salle de contrôle de l'admin (02/11)
-- =====================================================================
-- Une page qui VIT : les chiffres du jour, les commandes qui dérapent, la
-- carte, les boutiques et les livreurs. Une seule lecture, réservée aux
-- administrateurs ; les règles (quelle commande est une alerte, depuis
-- quand) sont dans le serveur (services/salleControle.ts), testées.
--
-- Positions en latitude/longitude : PostgREST renvoie sinon les colonnes
-- geography en binaire, illisible pour une carte.

create or replace function public.admin_salle_controle(p_depuis timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  resultat jsonb;
begin
  if not public.is_admin() then
    raise exception 'réservé à l’administration' using errcode = '42501';
  end if;

  with commandes as (
    select o.*
    from orders o
    where o.placed_at >= p_depuis
       or o.status not in ('delivered', 'cancelled')
  )
  select jsonb_build_object(
    'commandes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'type', c.type,
        'status', c.status,
        'total', c.total,
        'delivery_fee', c.delivery_fee,
        'placed_at', c.placed_at,
        'delivered_at', c.delivered_at,
        'scheduled_for', c.scheduled_for,
        'cancelled_reason', c.cancelled_reason,
        'dropoff_hint', c.dropoff_hint,
        'lat', case when c.dropoff_location is null then null else st_y(c.dropoff_location::geometry) end,
        'lng', case when c.dropoff_location is null then null else st_x(c.dropoff_location::geometry) end,
        'merchant_id', c.merchant_id,
        'driver_id', c.driver_id,
        'client_nom', p.full_name,
        'client_tel', p.phone,
        'historique', coalesce((
          select jsonb_agg(jsonb_build_object('status', h.status, 'le', h.created_at) order by h.created_at)
          from order_status_history h where h.order_id = c.id
        ), '[]'::jsonb)
      ) order by c.placed_at)
      from commandes c left join profiles p on p.id = c.user_id
    ), '[]'::jsonb),
    'boutiques', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'nom', m.name,
        'tel', m.phone,
        'lat', st_y(m.location::geometry),
        'lng', st_x(m.location::geometry),
        'ouverte', public.merchant_open_now(m.id)
      ))
      from merchants m
      where m.is_approved = true
        and (m.id in (select merchant_id from commandes where merchant_id is not null)
             or public.merchant_open_now(m.id))
    ), '[]'::jsonb),
    'livreurs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id,
        'nom', p.full_name,
        'tel', p.phone,
        'en_ligne', d.is_online,
        'disponible', d.is_available,
        'vu_le', d.last_seen_at,
        'lat', case when d.current_location is null then null else st_y(d.current_location::geometry) end,
        'lng', case when d.current_location is null then null else st_x(d.current_location::geometry) end
      ))
      from driver_profiles d join profiles p on p.id = d.id
    ), '[]'::jsonb),
    'signalements', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'message', s.message,
        'le', s.cree_le,
        'order_id', s.order_id,
        'client_nom', p.full_name,
        'client_tel', p.phone
      ) order by s.cree_le)
      from signalements s left join profiles p on p.id = s.user_id
      where s.statut = 'ouvert'
    ), '[]'::jsonb)
  ) into resultat;

  return resultat;
end;
$$;

revoke all on function public.admin_salle_controle(timestamptz) from public, anon;
grant execute on function public.admin_salle_controle(timestamptz) to authenticated;
