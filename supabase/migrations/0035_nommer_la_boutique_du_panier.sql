-- =====================================================================
-- 0035 — Dire CHEZ QUI le panier est ouvert
-- =====================================================================
-- Le panier est mono-boutique, et c'est volontaire : un livreur ne fait
-- qu'une course. Quand le client ajoute un article d'ailleurs, on lui
-- demande donc de trancher — vider, ou garder.
--
-- Mais on ne lui disait pas garder QUOI. Le message était « panier déjà
-- ouvert chez une autre boutique », et les deux boutons arrivaient sans que
-- rien ne nomme le commerce concerné. Le client doit alors se souvenir de
-- ce qu'il a mis dans son panier, parfois la veille, pour répondre.
--
-- Le nom est à une jointure de distance. Seul le message change ici : le
-- reste de la fonction est repris à l'identique de 0005.

create or replace function public.cart_add_item(
  p_product_id uuid,
  p_quantity   integer default 1,
  p_selections jsonb default '[]'::jsonb
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare
  v_cart_id     uuid;
  v_merchant_id uuid;
  v_current     uuid;
  v_price       integer;
  v_item_id     uuid;
  v_boutique    text;
begin
  if p_quantity is null or p_quantity < 1 then
    raise exception 'quantité invalide' using errcode = 'P0001';
  end if;

  select p.merchant_id into v_merchant_id
  from products p
  join merchants m on m.id = p.merchant_id
  where p.id = p_product_id and p.is_available and m.is_approved;

  if v_merchant_id is null then
    raise exception 'produit indisponible' using errcode = 'P0002';
  end if;

  v_price := public.compute_unit_price(p_product_id, p_selections);

  insert into carts (user_id, merchant_id)
  values (auth.uid(), v_merchant_id)
  on conflict (user_id) do update set updated_at = now()
  returning id, merchant_id into v_cart_id, v_current;

  if v_current is distinct from v_merchant_id then
    if exists (select 1 from cart_items where cart_id = v_cart_id) then
      select name into v_boutique from merchants where id = v_current;

      -- Ce message part tel quel jusqu'à l'écran : il est écrit pour être
      -- lu par le client, pas par un développeur.
      raise exception
        'Votre panier contient déjà des articles de %. Un livreur ne passe que dans une boutique à la fois.',
        coalesce(v_boutique, 'une autre boutique')
        using errcode = 'P0003';
    end if;
    update carts set merchant_id = v_merchant_id where id = v_cart_id;
  end if;

  -- Même produit, mêmes options : on incrémente au lieu d'empiler.
  select id into v_item_id
  from cart_items
  where cart_id = v_cart_id
    and product_id = p_product_id
    and selections = coalesce(p_selections, '[]'::jsonb);

  if v_item_id is not null then
    update cart_items
       set quantity = quantity + p_quantity, unit_price = v_price
     where id = v_item_id;
  else
    insert into cart_items (cart_id, product_id, quantity, selections, unit_price)
    values (v_cart_id, p_product_id, p_quantity, coalesce(p_selections, '[]'::jsonb), v_price)
    returning id into v_item_id;
  end if;

  return v_item_id;
end; $$;

notify pgrst, 'reload schema';
