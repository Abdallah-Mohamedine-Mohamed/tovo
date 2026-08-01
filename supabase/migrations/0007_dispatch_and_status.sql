-- =====================================================================
-- 0007 — Cycle de vie des commandes et sélection des livreurs
-- =====================================================================
-- LES TRANSITIONS SONT DANS UN TRIGGER, PAS DANS UNE RPC.
--
-- La tentation était de valider « qui a le droit de passer de quel statut à
-- quel autre » dans une fonction que le backend appelle. Ça ne protège
-- rien : la clé publishable est dans l'APK, donc publique, et n'importe qui
-- peut écrire directement via PostgREST sans passer par notre fonction. Un
-- boutiquier aurait pu marquer ses commandes « livrées » d'un simple
-- `update`.
--
-- Le trigger, lui, s'applique à toute écriture, quelle qu'en soit
-- l'origine. La RPC `advance_order_status()` n'est plus qu'une commodité.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Garde-fou des transitions
-- ---------------------------------------------------------------------

create or replace function public.guard_status_transition()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_key text;
  v_ok  boolean := false;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- auth.uid() est null quand l'écriture vient de la service_role : jobs,
  -- ETL, dispatch. Ces contextes n'ont pas d'utilisateur à contrôler.
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  v_key := old.status::text || '>' || new.status::text;

  -- Boutiquier : il pilote la préparation, jamais la course.
  if public.owns_merchant(old.merchant_id) then
    v_ok := v_key = any (array[
      'pending>confirmed',
      'confirmed>preparing',
      'preparing>ready',
      'pending>cancelled',
      'confirmed>cancelled'
    ]);
  end if;

  -- Livreur qui prend une course libre : il s'assigne et avance d'un cran
  -- dans le même mouvement.
  if not v_ok
     and old.driver_id is null
     and new.driver_id = auth.uid()
     and v_key = 'ready>assigned'
     and public.my_role() = 'driver' then
    v_ok := true;
  end if;

  -- Livreur déjà assigné : il pilote la course, jamais la préparation.
  if not v_ok and old.driver_id = auth.uid() then
    v_ok := v_key = any (array[
      'assigned>picked_up',
      'picked_up>delivering',
      'delivering>delivered'
    ]);
  end if;

  -- Client : il peut renoncer tant que la préparation n'a pas commencé.
  if not v_ok and old.user_id = auth.uid() then
    v_ok := v_key = any (array['pending>cancelled', 'confirmed>cancelled']);
  end if;

  if not v_ok then
    raise exception 'transition % non autorisée', v_key using errcode = 'P0003';
  end if;

  return new;
end; $$;

drop trigger if exists trg_guard_status on orders;
create trigger trg_guard_status
  before update of status on orders
  for each row execute function guard_status_transition();

-- Le livreur redevient disponible dès que la course se termine, quelle
-- qu'en soit l'issue. En trigger et non dans la RPC, pour que ce soit vrai
-- même quand le statut change par un autre chemin.
create or replace function public.release_driver()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('delivered', 'cancelled')
     and old.status is distinct from new.status
     and new.driver_id is not null then
    update driver_profiles set is_available = true where id = new.driver_id;
  end if;
  return null;
end; $$;

drop trigger if exists trg_release_driver on orders;
create trigger trg_release_driver
  after update of status on orders
  for each row execute function release_driver();

-- Le client doit pouvoir annuler : sans policy d'update, la RLS le
-- bloquerait avant même que le trigger ne se prononce. Le trigger reste le
-- garde-fou — cette policy ouvre la porte, elle ne dispense pas du contrôle.
drop policy if exists orders_client_update on orders;
create policy orders_client_update on orders for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- API de changement de statut
-- ---------------------------------------------------------------------
-- Simple commodité : l'autorisation est déjà tranchée par le trigger.

create or replace function public.advance_order_status(
  p_order_id uuid,
  p_status   order_status,
  p_note     text default null
)
returns order_status
language plpgsql security invoker set search_path = public as $$
declare
  v_touched integer;
begin
  update orders set status = p_status where id = p_order_id;
  get diagnostics v_touched = row_count;

  -- Zéro ligne touchée = la RLS a masqué la commande. On ne distingue pas
  -- « inexistante » de « pas à vous » : la différence renseignerait un
  -- curieux sur ce qui existe.
  if v_touched = 0 then
    raise exception 'commande introuvable' using errcode = 'P0002';
  end if;

  if p_note is not null then
    update order_status_history
       set note = p_note
     where id = (
       select h.id from order_status_history h
       where h.order_id = p_order_id and h.status = p_status
       order by h.created_at desc
       limit 1
     );
  end if;

  return p_status;
end; $$;

-- ---------------------------------------------------------------------
-- Sélection des livreurs candidats
-- ---------------------------------------------------------------------
-- Appelée exclusivement par le job de dispatch, avec la service_role.
-- SECURITY DEFINER pour lire les positions, mais refusée à tout utilisateur
-- authentifié : sans ce garde-fou, n'importe qui obtiendrait la position de
-- tous les livreurs de la ville.

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

  -- Le livreur part du point de collecte : la boutique pour une livraison,
  -- l'adresse de prise en charge pour une course coursier.
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
    and (d.zone_id is null or d.zone_id = v_order.zone_id)
    and st_dwithin(d.current_location, v_origin, v_radius)
    -- Un livreur silencieux depuis plus de deux minutes a probablement fermé
    -- l'app ou perdu le réseau. Le notifier ferait perdre du temps à tout le
    -- monde, à commencer par le client qui attend.
    and (d.last_seen_at is null or d.last_seen_at > now() - interval '2 minutes')
  order by d.current_location <-> v_origin
  limit greatest(v_limit, 1);
end; $$;

-- ---------------------------------------------------------------------
-- Position du livreur
-- ---------------------------------------------------------------------
-- Un seul appel : écrire le ping et rafraîchir le profil. Deux requêtes
-- séparées toutes les dix secondes, c'est le double d'allers-retours sur un
-- réseau déjà fragile, et le double de batterie.

create or replace function public.push_driver_location(
  p_lat      double precision,
  p_lng      double precision,
  p_order_id uuid default null,
  p_heading  numeric default null,
  p_speed    numeric default null
)
returns void language plpgsql security invoker set search_path = public as $$
declare
  v_point geography;
begin
  v_point := st_setsrid(st_point(p_lng, p_lat), 4326)::geography;

  insert into driver_locations (driver_id, order_id, location, heading, speed_kmh)
  values (auth.uid(), p_order_id, v_point, p_heading, p_speed);

  update driver_profiles
     set current_location = v_point,
         last_seen_at = now()
   where id = auth.uid();
end; $$;

notify pgrst, 'reload schema';
