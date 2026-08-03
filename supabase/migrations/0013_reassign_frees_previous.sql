-- =====================================================================
-- 0013 — Changer de livreur libère le précédent
-- =====================================================================
-- Une commande assignée ne retourne pas au pool : on change simplement de
-- livreur. La remettre en attente la rendrait de nouveau orpheline, ce
-- qu'on vient justement de corriger.
--
-- Mais réassigner sans libérer l'ancien le laissait marqué « en course »
-- indéfiniment. Il aurait disparu du dispatch — `dispatch_candidates`
-- filtre sur `is_available` — sans qu'aucune erreur ne l'explique. Un
-- livreur en ligne, à côté du restaurant, que le système ignore.
-- =====================================================================

drop function if exists public.admin_unassign_driver(uuid);

create or replace function public.admin_assign_driver(
  p_order_id  uuid,
  p_driver_id uuid
)
returns boolean
language plpgsql security invoker set search_path = public as $$
declare
  v_statut    order_status;
  v_precedent uuid;
begin
  if not public.is_admin() then
    raise exception 'réservé aux administrateurs' using errcode = '42501';
  end if;

  select status, driver_id into v_statut, v_precedent
  from orders where id = p_order_id;

  if v_statut is null then
    raise exception 'commande introuvable' using errcode = 'P0002';
  end if;

  if v_statut in ('delivered', 'cancelled') then
    raise exception 'commande déjà terminée' using errcode = 'P0003';
  end if;

  if v_precedent = p_driver_id then
    return true;
  end if;

  update orders
     set driver_id = p_driver_id,
         status = case when status = 'ready' then 'assigned' else status end
   where id = p_order_id;

  update driver_profiles set is_available = false where id = p_driver_id;

  -- L'ancien livreur redevient disponible — sauf s'il a une autre course en
  -- cours, auquel cas le libérer le ferait apparaître comme libre alors
  -- qu'il roule déjà.
  if v_precedent is not null then
    update driver_profiles d
       set is_available = true
     where d.id = v_precedent
       and not exists (
         select 1 from orders o
         where o.driver_id = v_precedent
           and o.id <> p_order_id
           and o.status in ('assigned', 'picked_up', 'delivering')
       );
  end if;

  return true;
end; $$;

notify pgrst, 'reload schema';
