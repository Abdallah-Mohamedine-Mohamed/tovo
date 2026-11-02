-- =====================================================================
-- 0090 — Un article manque (02/11)
-- =====================================================================
-- « Produit non disponible » était LA première cause d'annulation de
-- l'ancienne application : 741 commandes. La boutique n'avait que deux
-- gestes, tout accepter ou tout refuser.
--
-- Désormais : la boutique coche l'article qui manque ; le client choisit
-- de le remplacer (deux propositions de la même boutique, au même prix),
-- de le retirer, ou d'annuler ; sans réponse en 10 minutes, l'article est
-- retiré et la commande continue. L'article passe « à vérifier » dans le
-- catalogue : il n'est plus proposé jusqu'à ce que la boutique le remette.
--
-- Les écritures passent par le serveur (routes/articlesManquants.ts) ; la
-- base garde les faits et recalcule les montants.

create table if not exists public.articles_manquants (
  id                       uuid primary key default gen_random_uuid(),
  order_id                 uuid not null references public.orders(id) on delete cascade,
  order_item_id            uuid references public.order_items(id) on delete set null,
  product_id               uuid references public.products(id) on delete set null,
  nom                      text not null,
  quantite                 integer not null,
  prix_unitaire            integer not null,
  -- Jusqu'à deux remplacements proposés : [{product_id, nom, prix, image_url}]
  suggestions              jsonb not null default '[]'::jsonb,
  signale_le               timestamptz not null default now(),
  decision                 text not null default 'attente'
                           check (decision in ('attente', 'remplacer', 'retirer', 'annuler')),
  remplacement_product_id  uuid references public.products(id) on delete set null,
  decide_le                timestamptz,
  decide_par               text check (decide_par in ('client', 'auto', 'admin'))
);
create index if not exists articles_manquants_commande on public.articles_manquants(order_id);
create index if not exists articles_manquants_attente on public.articles_manquants(signale_le) where decision = 'attente';

alter table public.articles_manquants enable row level security;
-- Le client de la commande, la boutique de la commande et l'administration lisent.
drop policy if exists articles_manquants_lecture on public.articles_manquants;
create policy articles_manquants_lecture on public.articles_manquants
  for select using (
    public.is_admin()
    or exists (
      select 1 from public.orders o
      left join public.merchants m on m.id = o.merchant_id
      where o.id = articles_manquants.order_id
        and (o.user_id = auth.uid() or m.owner_id = auth.uid())
    )
  );

-- Le client n'a pas encore répondu : la boutique ne peut pas accepter.
alter table public.orders add column if not exists attente_client boolean not null default false;

-- « À vérifier » dans le catalogue de la boutique : quand l'article a manqué.
alter table public.products add column if not exists manquant_le timestamptz;

-- Les montants après un remplacement ou un retrait, avec les mêmes règles
-- que la commande d'origine (commission, versement à la boutique).
create or replace function public.recalculer_commande(p_order_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_items integer;
  v_commission integer;
begin
  select coalesce(sum(line_total), 0) into v_items from order_items where order_id = p_order_id;
  v_commission := public.commission_for(v_items);
  update orders set
    items_total = v_items,
    commission_amount = v_commission,
    merchant_payout = v_items - v_commission,
    total = greatest(0, v_items + delivery_fee - discount)
  where id = p_order_id;
end;
$$;
revoke all on function public.recalculer_commande(uuid) from public, anon, authenticated;
grant execute on function public.recalculer_commande(uuid) to service_role;

-- La salle de contrôle voit les articles manquants qui attendent le client.
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
    'manquants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', am.id, 'order_id', am.order_id, 'nom', am.nom, 'le', am.signale_le
      ) order by am.signale_le)
      from articles_manquants am where am.decision = 'attente'
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
