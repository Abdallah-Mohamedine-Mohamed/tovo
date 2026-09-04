-- =====================================================================
-- 0045 — Recommander ce qu'on a déjà pris
-- =====================================================================
-- Le bouton existait déjà : `historique_commandes` proposait
-- « Recommander (4500 F) » avec la valeur `recommander:<id>`.
--
-- SAUF QUE RIEN NE TRAITAIT CETTE VALEUR. Ni outil, ni route, ni geste dans
-- l'application. Le bouton partait vers l'assistant, qui n'avait aucun moyen
-- de remettre les articles au panier. Un bouton qui ne fait rien coûte plus
-- cher qu'un bouton absent : le client essaie, il ne se passe rien, et il
-- cesse de croire au reste.
--
-- Son libellé ne disait pas non plus QUOI recommander — un montant, et rien
-- d'autre. « Recommander (4500 F) » ne rappelle à personne ce qu'il a mangé.
--
-- CETTE FONCTION NE DUPLIQUE AUCUNE RÈGLE. Elle rappelle `cart_add_item`
-- ligne par ligne, ce qui lui fait hériter de tout : produit encore
-- disponible, boutique encore approuvée, PRIX RECALCULÉ AU TARIF DU JOUR.
-- Recopier l'ancien prix serait une faute — un plat à 3 000 F en avril n'est
-- pas à 3 000 F aujourd'hui, et c'est le boutiquier qui paierait l'écart.
--
-- DEUX ÉCHECS, DEUX TRAITEMENTS.
--
--   Un produit disparu du catalogue ne doit pas faire échouer toute la
--   commande : on le met de côté, on reprend le reste, et on DIT lequel
--   manque. Reprendre trois articles sur quatre en silence enverrait le
--   client au paiement avec un panier incomplet.
--
--   Un panier déjà ouvert chez une autre boutique, en revanche, remonte tel
--   quel : c'est un arbitrage qui appartient au client, et l'application sait
--   déjà le lui poser — « vider et recommencer » ou « garder mon panier ».

create or replace function public.reorder_into_cart(p_order_id uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  v_ligne    record;
  v_repris   integer := 0;
  v_ignores  text[] := '{}';
begin
  -- La RLS empêcherait déjà de lire la commande d'autrui, mais un panier
  -- vide sans explication est un mauvais message d'erreur.
  if not exists (
    select 1 from orders o
    where o.id = p_order_id and o.user_id = auth.uid()
  ) then
    raise exception 'commande introuvable' using errcode = 'P0002';
  end if;

  for v_ligne in
    select oi.product_id, oi.quantity, oi.selections, oi.product_name
    from order_items oi
    where oi.order_id = p_order_id
    order by oi.id
  loop
    begin
      perform public.cart_add_item(
        v_ligne.product_id,
        v_ligne.quantity,
        coalesce(v_ligne.selections, '[]'::jsonb)
      );
      v_repris := v_repris + 1;
    exception
      -- P0002 seulement : le produit n'existe plus ou n'est plus disponible.
      -- Tout le reste — et notamment le conflit de boutique en P0003 —
      -- remonte, parce que ces cas-là demandent une décision du client.
      when sqlstate 'P0002' then
        v_ignores := array_append(v_ignores, v_ligne.product_name);
    end;
  end loop;

  if v_repris = 0 and array_length(v_ignores, 1) > 0 then
    raise exception 'plus rien de cette commande n''est disponible'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object('repris', v_repris, 'ignores', to_jsonb(v_ignores));
end; $$;

comment on function public.reorder_into_cart(uuid) is
  'Remet au panier les articles d''une commande passée, aux prix du jour. Les produits devenus indisponibles sont rendus dans « ignores » plutôt que d''être omis en silence.';

-- ---------------------------------------------------------------------
-- La dernière commande, pour la proposer d'entrée
-- ---------------------------------------------------------------------
-- L'accueil montre neuf tuiles de catégories à quelqu'un qui, la plupart du
-- temps, veut reprendre ce qu'il a pris la dernière fois. Cette fonction
-- donne de quoi le lui proposer en une ligne et un bouton.

create or replace function public.last_delivered_order()
returns jsonb language sql stable security invoker set search_path = public as $$
  -- Aucune ligne : une fonction SQL rend NULL d'elle-même. Pas besoin
  -- de tester l'absence, il suffit de ne rien trouver.
  select jsonb_build_object(
    'order_id',      o.id,
    'total',         o.total,
    'delivered_at',  o.delivered_at,
    'merchant_name', m.name,
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object('nom', oi.product_name, 'quantite', oi.quantity)
                       order by oi.line_total desc)
      from order_items oi where oi.order_id = o.id
    ), '[]'::jsonb)
  )
  from (
    select * from orders
    where user_id = auth.uid()
      and status = 'delivered'
      and type = 'delivery'
      -- TRENTE JOURS, pas « la dernière quelle qu'elle soit ». Proposer de
      -- reprendre un plat commandé il y a trois mois n'est pas une
      -- suggestion, c'est un encombrement : ça occupe le haut de
      -- l'écran et repousse le catalogue pour une envie éteinte.
      and delivered_at > now() - interval '30 days'
    order by delivered_at desc nulls last
    limit 1
  ) o
  left join merchants m on m.id = o.merchant_id;
$$;

comment on function public.last_delivered_order() is
  'La dernière commande livrée du client, avec ses articles. Sert à proposer « comme la dernière fois » dès l''accueil, sans lui faire traverser le catalogue.';

notify pgrst, 'reload schema';
