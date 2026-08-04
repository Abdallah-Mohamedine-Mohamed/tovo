-- =====================================================================
-- 0017 — Paiement Nita : suivi automatique, décision humaine
-- =====================================================================
-- Nita n'est pas un débit instantané. On crée un « achat en ligne », Nita
-- renvoie un code, et le client le règle au guichet ou depuis MYNITA.
--
-- Mais le client peut aussi bien envoyer l'argent DIRECTEMENT par Nita, sans
-- passer par l'achat en ligne. Aucune API ne peut alors constater le
-- paiement : seul celui qui encaisse le sait. C'est pourquoi le système
-- surveille l'achat en ligne sans jamais en dépendre, et laisse le dernier
-- mot au livreur ou à l'admin au moment de la livraison.
--
-- Le paiement ne freine donc rien : la commande part chez le boutiquier dès
-- qu'elle est passée, quel que soit son mode de règlement.

-- ---------------------------------------------------------------------
-- Qui a dit que c'était payé
-- ---------------------------------------------------------------------
-- Il s'agit d'argent. Un paiement constaté par Nita et un paiement déclaré
-- par un livreur n'ont pas la même valeur de preuve : si un encaissement
-- manque à l'appel, il faut pouvoir remonter à qui l'a déclaré reçu.
-- `payment_confirmed_by` à null signifie « constaté par Nita ».

alter table orders add column if not exists payment_confirmed_by uuid references profiles(id);
alter table orders add column if not exists payment_confirmed_at timestamptz;

comment on column orders.payment_confirmed_by is
  'Qui a déclaré le paiement reçu. NULL = constaté automatiquement chez Nita.';

-- ---------------------------------------------------------------------
-- Constat automatique
-- ---------------------------------------------------------------------

/*
 * Enregistre un paiement constaté chez Nita.
 *
 * Réservée au backend (clé de service) et à l'admin : ouverte au client,
 * elle permettrait de se déclarer payé soi-même.
 *
 * Idempotente : Nita peut rappeler plusieurs fois, et notre vérification
 * périodique tombera parfois en même temps que son rappel. Ne renvoie vrai
 * qu'au passage effectif, pour ne prévenir qu'une fois.
 */
create or replace function public.mark_order_paid(
  p_order_id  uuid,
  p_reference text default null
)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_change integer;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'reserve au service' using errcode = '42501';
  end if;

  update orders
     set payment_status       = 'paid',
         payment_ref          = coalesce(p_reference, payment_ref),
         payment_confirmed_by = null,
         payment_confirmed_at = now()
   where id = p_order_id
     and payment_status = 'pending';

  get diagnostics v_change = row_count;
  return v_change > 0;
end $$;

/*
 * Achat annulé ou bloqué chez Nita.
 *
 * On ne touche pas au statut de la commande : elle continue son chemin, et
 * le livreur encaissera. L'achat en ligne n'était qu'un moyen de payer parmi
 * d'autres, pas une condition de la livraison.
 */
create or replace function public.mark_order_payment_failed(p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_change integer;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'reserve au service' using errcode = '42501';
  end if;

  update orders
     set payment_status = 'failed'
   where id = p_order_id
     and payment_status = 'pending';

  get diagnostics v_change = row_count;
  return v_change > 0;
end $$;

-- ---------------------------------------------------------------------
-- Constat humain
-- ---------------------------------------------------------------------

/*
 * Le livreur ou l'admin déclare avoir constaté le paiement.
 *
 * C'est le seul recours quand le client a envoyé l'argent directement par
 * Nita plutôt que de régler l'achat en ligne : le système n'a alors aucun
 * moyen de le savoir.
 *
 * Restreinte au livreur ASSIGNÉ à cette commande et à l'admin. Sans cette
 * restriction, n'importe quel livreur connecté pourrait solder la commande
 * d'un autre, et le client n'aurait jamais à payer.
 */
create or replace function public.confirm_payment_received(p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_change integer;
  v_driver uuid;
begin
  select driver_id into v_driver from orders where id = p_order_id;

  if not public.is_admin() and (v_driver is null or v_driver <> auth.uid()) then
    raise exception 'seul le livreur assigne ou un admin peut confirmer un encaissement'
      using errcode = '42501';
  end if;

  update orders
     set payment_status       = 'paid',
         payment_confirmed_by = auth.uid(),
         payment_confirmed_at = now()
   where id = p_order_id
     and payment_status in ('pending', 'failed');

  get diagnostics v_change = row_count;
  return v_change > 0;
end $$;

-- ---------------------------------------------------------------------
-- Les paiements dont on attend encore des nouvelles
-- ---------------------------------------------------------------------

/*
 * Commandes à revérifier auprès de Nita.
 *
 * Le rappel de Nita peut ne jamais arriver : serveur redéployé, réseau
 * coupé, panne chez eux. Sans reprise, un client qui a réglé son achat
 * serait quand même sollicité par le livreur — et paierait deux fois.
 *
 * @param p_age_max_min au-delà, on cesse d'interroger Nita : la commande est
 *        livrée depuis longtemps et le livreur a tranché.
 */
create or replace function public.orders_awaiting_payment(
  p_age_max_min integer default 720,
  p_limite      integer default 50
)
returns table (id uuid, payment_ref text, placed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.payment_ref, o.placed_at
  from orders o
  where o.payment_method = 'mobile_money'
    and o.payment_status = 'pending'
    and o.payment_ref is not null
    and o.placed_at > now() - make_interval(mins => p_age_max_min)
  order by o.placed_at
  limit p_limite
$$;

revoke all on function public.mark_order_paid(uuid, text) from anon, authenticated;
revoke all on function public.mark_order_payment_failed(uuid) from anon, authenticated;
revoke all on function public.orders_awaiting_payment(integer, integer) from anon, authenticated;
-- `confirm_payment_received` reste appelable par les connectés : elle vérifie
-- elle-même que l'appelant est le livreur assigné ou un admin.

notify pgrst, 'reload schema';
