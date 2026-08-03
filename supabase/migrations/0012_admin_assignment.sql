-- =====================================================================
-- 0012 — Assignation manuelle par l'admin
-- =====================================================================
-- Le dispatch automatique couvre le cas normal. Il ne couvre pas la nuit où
-- deux livreurs seulement sont en ligne, la panne de réseau qui empêche les
-- notifications d'arriver, ou la commande à l'autre bout de la ville que
-- personne ne veut prendre.
--
-- Dans ces cas, quelqu'un doit pouvoir décrocher son téléphone, appeler un
-- livreur, et lui attribuer la course à la main. Sans cette porte de sortie,
-- une commande non prise reste bloquée et le client attend sans réponse.
--
-- Une commande n'est jamais retirée à l'admin : le seuil de fraîcheur ne
-- l'écarte que du pool des livreurs et du dispatch automatique.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Toutes les commandes actives, dispatchables ou non
-- ---------------------------------------------------------------------

create or replace function public.admin_orders(
  p_bloquees_seulement boolean default false
)
returns table (
  id             uuid,
  status         order_status,
  type           order_type,
  total          integer,
  driver_earning integer,
  placed_at      timestamptz,
  attente_min    integer,
  dropoff_hint   text,
  merchant_name  text,
  driver_name    text,
  dispatchable   boolean
)
language sql stable security invoker set search_path = public as $$
  select
    o.id,
    o.status,
    o.type,
    o.total,
    o.driver_earning,
    o.placed_at,
    (extract(epoch from (now() - o.placed_at)) / 60)::integer,
    o.dropoff_hint,
    m.name,
    pr.full_name,
    -- Visible ou non dans le pool des livreurs. C'est cette colonne qui
    -- signale à l'admin les commandes qu'il doit prendre en charge.
    (o.status = 'ready'
      and o.driver_id is null
      and o.placed_at > now() - make_interval(
        mins => (select order_stale_after_min from platform_settings)))
  from orders o
  left join merchants m on m.id = o.merchant_id
  left join profiles pr on pr.id = o.driver_id
  where o.status not in ('delivered', 'cancelled')
    and (
      not p_bloquees_seulement
      or (o.status = 'ready'
          and o.driver_id is null
          and o.placed_at <= now() - make_interval(
            mins => (select order_stale_after_min from platform_settings)))
    )
  order by o.placed_at asc
  limit 200;
$$;

-- ---------------------------------------------------------------------
-- Livreurs assignables
-- ---------------------------------------------------------------------
-- Volontairement plus permissif que `dispatch_candidates` : l'admin choisit
-- en connaissance de cause, y compris un livreur éloigné ou silencieux
-- depuis un moment, parce qu'il vient peut-être de l'avoir au téléphone.

create or replace function public.admin_assignable_drivers(p_order_id uuid)
returns table (
  driver_id    uuid,
  full_name    text,
  phone        text,
  is_online    boolean,
  is_available boolean,
  last_seen_at timestamptz,
  distance_m   integer
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_origin geography;
  v_order  record;
begin
  if not public.is_admin() then
    raise exception 'réservé aux administrateurs' using errcode = '42501';
  end if;

  select o.id, o.merchant_id, o.type into v_order from orders o where o.id = p_order_id;

  if v_order.type = 'courier' then
    select cd.pickup_location into v_origin
    from courier_details cd where cd.order_id = p_order_id;
  else
    select m.location into v_origin
    from merchants m where m.id = v_order.merchant_id;
  end if;

  return query
  select
    d.id,
    pr.full_name,
    pr.phone,
    d.is_online,
    d.is_available,
    d.last_seen_at,
    case when v_origin is null or d.current_location is null then null
         else st_distance(d.current_location, v_origin)::integer end
  from driver_profiles d
  join profiles pr on pr.id = d.id
  order by
    d.is_available desc,
    d.is_online desc,
    case when v_origin is null or d.current_location is null then 1 else 0 end,
    st_distance(d.current_location, v_origin)
  limit 30;
end; $$;

-- ---------------------------------------------------------------------
-- Assignation
-- ---------------------------------------------------------------------

create or replace function public.admin_assign_driver(
  p_order_id  uuid,
  p_driver_id uuid
)
returns boolean
language plpgsql security invoker set search_path = public as $$
declare
  v_statut order_status;
begin
  if not public.is_admin() then
    raise exception 'réservé aux administrateurs' using errcode = '42501';
  end if;

  select status into v_statut from orders where id = p_order_id;

  if v_statut is null then
    raise exception 'commande introuvable' using errcode = 'P0002';
  end if;

  if v_statut in ('delivered', 'cancelled') then
    raise exception 'commande déjà terminée' using errcode = 'P0003';
  end if;

  -- Le trigger de transition laisse passer l'admin, y compris depuis un
  -- statut que le dispatch automatique n'aurait pas accepté.
  update orders
     set driver_id = p_driver_id,
         status = case when status = 'ready' then 'assigned' else status end
   where id = p_order_id;

  update driver_profiles set is_available = false where id = p_driver_id;

  return true;
end; $$;

-- Retirer un livreur d'une course, pour la remettre au pool.
create or replace function public.admin_unassign_driver(p_order_id uuid)
returns boolean
language plpgsql security invoker set search_path = public as $$
declare
  v_driver uuid;
begin
  if not public.is_admin() then
    raise exception 'réservé aux administrateurs' using errcode = '42501';
  end if;

  select driver_id into v_driver from orders where id = p_order_id;

  update orders
     set driver_id = null,
         status = case when status in ('assigned', 'picked_up') then 'ready' else status end
   where id = p_order_id;

  if v_driver is not null then
    update driver_profiles set is_available = true where id = v_driver;
  end if;

  return true;
end; $$;

notify pgrst, 'reload schema';
