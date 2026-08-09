-- =====================================================================
-- 0026 — Annuler tant que le livreur n'est pas parti
-- =====================================================================
-- Le client pouvait déjà renoncer, mais seulement en « pending » et
-- « confirmed » : dès que le boutiquier commençait à préparer, il n'avait
-- plus aucun recours et devait téléphoner.
--
-- LA RÈGLE, décidée avec le fondateur :
--
--   Annulable tant qu'aucun livreur n'est en route. On ajoute donc
--   « preparing » et « ready ». Après, quelqu'un a pris la course, s'est
--   déplacé, et parfois avancé l'argent du repas : ce n'est plus au client
--   seul d'en décider.
--
--   Un paiement Nita déjà réglé bloque l'annulation. L'argent est encaissé ;
--   le rendre suppose un remboursement, qui se traite à la main et ne peut
--   pas être déclenché par un geste dans l'application.
--
-- Le trigger est repris À L'IDENTIQUE, à une liste près. Il énumère des
-- transitions précises — « pending>confirmed », « preparing>ready » — et
-- c'est ce qui empêche un boutiquier de marquer livrée une commande que
-- personne n'a portée, ou de revenir en arrière. Une réécriture qui
-- remplacerait ces listes par un simple « le boutiquier a le droit »
-- ouvrirait exactement ces portes.

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

  -- Client : il renonce tant que personne n'est parti livrer.
  --
  -- « preparing » et « ready » sont les deux ajouts. La condition sur
  -- `driver_id` compte autant que la liste : une commande « ready » qu'un
  -- livreur vient d'accepter porte encore ce statut le temps que la
  -- transition s'écrive, et l'annuler alors le laisserait sur le pas de la
  -- porte.
  if not v_ok and old.user_id = auth.uid() and old.driver_id is null then
    v_ok := v_key = any (array[
      'pending>cancelled',
      'confirmed>cancelled',
      'preparing>cancelled',
      'ready>cancelled'
    ]);
  end if;

  if not v_ok then
    raise exception 'transition % non autorisée', v_key using errcode = 'P0003';
  end if;

  return new;
end; $$;

/*
 * Annuler sa commande, avec une raison compréhensible en cas de refus.
 *
 * @returns le motif du refus, ou null si l'annulation a eu lieu.
 *
 * Renvoyer le motif plutôt que laisser remonter l'exception du trigger : le
 * client doit lire « votre livreur est déjà en route », pas
 * « transition ready>cancelled non autorisée ».
 */
create or replace function public.cancel_my_order(
  p_order_id uuid,
  p_motif    text default null
)
returns text
language plpgsql security invoker set search_path = public as $$
declare
  v_commande record;
begin
  select user_id, status, driver_id, payment_method, payment_status
    into v_commande
  from orders
  where id = p_order_id;

  -- La RLS masque déjà les commandes des autres : on ne distingue pas
  -- « pas à vous » de « inexistante », la différence renseignerait un
  -- curieux sur ce qui existe.
  if v_commande is null then
    return 'Commande introuvable.';
  end if;

  if v_commande.status in ('delivered', 'cancelled') then
    return 'Cette commande est déjà terminée.';
  end if;

  if v_commande.driver_id is not null
     or v_commande.status in ('assigned', 'picked_up', 'delivering') then
    return 'Votre livreur est déjà en route. Appelez-le pour convenir de la suite.';
  end if;

  -- Argent encaissé : le remboursement se traite à la main, jamais par un
  -- geste dans l'application.
  if v_commande.payment_method = 'mobile_money'
     and v_commande.payment_status = 'paid' then
    return 'Cette commande est déjà payée. Contactez-nous pour un remboursement.';
  end if;

  update orders
     set status = 'cancelled',
         cancelled_reason = coalesce(nullif(trim(p_motif), ''), 'Annulée par le client')
   where id = p_order_id;

  return null;
end $$;

notify pgrst, 'reload schema';
