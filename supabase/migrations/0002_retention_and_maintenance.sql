-- =====================================================================
-- 0002 — Rétention et maintenance
-- =====================================================================
-- driver_locations reçoit un ping toutes les 10 s par livreur en course.
-- 50 livreurs actifs 10 h/jour ≈ 1,8 M de lignes par mois. Sans purge, la
-- table devient le plus gros objet de la base en quelques semaines.
--
-- On garde 24 h : au-delà, le suivi live n'a plus d'usage et le trajet
-- historique n'est pas un besoin produit v1.
-- =====================================================================

create extension if not exists pg_cron;

create or replace function public.purge_driver_locations()
returns void language sql security definer set search_path = public as $$
  delete from driver_locations where recorded_at < now() - interval '24 hours';
$$;

-- Purge des offres externes expirées : elles sont re-fetchées à la demande.
create or replace function public.purge_external_offers()
returns void language sql security definer set search_path = public as $$
  delete from external_offers where expires_at < now() - interval '7 days';
$$;

select cron.schedule(
  'purge-driver-locations',
  '17 * * * *',                       -- toutes les heures, à la minute 17
  $$select public.purge_driver_locations()$$
);

select cron.schedule(
  'purge-external-offers',
  '43 3 * * *',                       -- une fois par nuit
  $$select public.purge_external_offers()$$
);

-- ---------------------------------------------------------------------
-- Verrou d'attribution de course
-- ---------------------------------------------------------------------
-- Le dispatch notifie les 3 livreurs les plus proches. Sans verrou, deux
-- acceptations simultanées se marchent dessus. Cette fonction rend
-- l'acceptation atomique : le premier gagne, les autres reçoivent false.

create or replace function public.accept_order(target_order uuid)
returns boolean
language plpgsql security invoker set search_path = public as $$
declare
  claimed integer;
begin
  update orders
     set driver_id = auth.uid(),
         status    = 'assigned'
   where id = target_order
     and driver_id is null
     and status = 'ready';

  get diagnostics claimed = row_count;

  if claimed = 1 then
    update driver_profiles set is_available = false where id = auth.uid();
    return true;
  end if;

  return false;
end; $$;

-- ---------------------------------------------------------------------
-- Encaissement cash à la livraison
-- ---------------------------------------------------------------------
-- Écrit la ligne de collecte au moment où la commande passe à 'delivered',
-- pour que le solde du jour du livreur ne dépende pas d'un appel côté app
-- (qui peut se perdre en mode hors ligne).

create or replace function public.record_cash_collection()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'delivered'
     and old.status is distinct from 'delivered'
     and new.payment_method = 'cash'
     and new.driver_id is not null then
    insert into driver_cash_ledger (driver_id, order_id, entry_type, amount, note)
    values (new.driver_id, new.id, 'collection', new.total, 'Encaissement à la livraison')
    on conflict do nothing;
  end if;
  return new;
end; $$;

drop trigger if exists trg_record_cash on orders;
create trigger trg_record_cash
  after update of status on orders
  for each row execute function record_cash_collection();

-- Une seule ligne de collecte par commande.
create unique index if not exists idx_cash_one_collection_per_order
  on driver_cash_ledger(order_id)
  where entry_type = 'collection';
