-- =====================================================================
-- 0011 — Commandes prêtes abandonnées
-- =====================================================================
-- Le pool des livreurs renvoyait les 20 plus anciennes commandes prêtes,
-- classées par ancienneté. C'est le bon ordre — le premier arrivé doit être
-- servi le premier — mais sans borne de fraîcheur, des commandes jamais
-- prises occupent les 20 places indéfiniment.
--
-- Conséquence observée sur la base de staging : 34 commandes prêtes
-- abandonnées, la plus ancienne datant de la veille. Un livreur ne voyait
-- plus AUCUNE course récente, sans qu'aucune erreur n'apparaisse nulle part.
--
-- Le balayage de dispatch souffrait du même défaut : il redispatchait ces
-- commandes toutes les minutes, notifiant les livreurs pour des courses
-- périmées.
--
-- Une commande qui reste prête au-delà du seuil n'est pas annulée — annuler
-- la commande d'un client est une décision commerciale, pas technique. Elle
-- sort simplement du pool et du dispatch, et devient visible à l'admin.
-- =====================================================================

alter table platform_settings
  add column if not exists order_stale_after_min integer not null default 60;

-- ---------------------------------------------------------------------
-- Pool des livreurs
-- ---------------------------------------------------------------------
-- En fonction plutôt qu'en requête côté backend : le seuil vient des
-- réglages, et la RLS s'applique quand même puisque la fonction est
-- SECURITY INVOKER — un livreur ne voit que ce que sa zone lui autorise.

create or replace function public.driver_pool()
returns table (
  id             uuid,
  type           order_type,
  total          integer,
  driver_earning integer,
  dropoff_hint   text,
  placed_at      timestamptz,
  merchant_id    uuid,
  merchant_name  text,
  attente_min    integer
)
language sql stable security invoker set search_path = public as $$
  select
    o.id,
    o.type,
    o.total,
    o.driver_earning,
    o.dropoff_hint,
    o.placed_at,
    o.merchant_id,
    m.name,
    (extract(epoch from (now() - o.placed_at)) / 60)::integer
  from orders o
  left join merchants m on m.id = o.merchant_id
  where o.status = 'ready'
    and o.driver_id is null
    and o.placed_at > now() - make_interval(
      mins => (select order_stale_after_min from platform_settings)
    )
  -- Du plus ancien au plus récent : le client qui attend depuis le plus
  -- longtemps passe en premier. La borne ci-dessus empêche qu'une commande
  -- abandonnée bloque la file pour toujours.
  order by o.placed_at asc
  limit 20;
$$;

-- ---------------------------------------------------------------------
-- Commandes bloquées, pour l'admin
-- ---------------------------------------------------------------------
-- Ce que plus personne ne voit doit rester visible à quelqu'un.

create or replace function public.stale_orders()
returns table (
  id           uuid,
  placed_at    timestamptz,
  attente_min  integer,
  total        integer,
  dropoff_hint text,
  merchant_id  uuid
)
language sql stable security invoker set search_path = public as $$
  select
    o.id,
    o.placed_at,
    (extract(epoch from (now() - o.placed_at)) / 60)::integer,
    o.total,
    o.dropoff_hint,
    o.merchant_id
  from orders o
  where o.status = 'ready'
    and o.driver_id is null
    and o.placed_at <= now() - make_interval(
      mins => (select order_stale_after_min from platform_settings)
    )
  order by o.placed_at asc
  limit 100;
$$;

notify pgrst, 'reload schema';
