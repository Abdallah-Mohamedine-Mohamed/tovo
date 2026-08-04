-- =====================================================================
-- 0018 — Avis vérifiés et adresses enregistrées
-- =====================================================================

-- ---------------------------------------------------------------------
-- Un avis suppose une commande livrée
-- ---------------------------------------------------------------------
-- La policy `reviews_owner` n'exigeait que `user_id = auth.uid()`. Un client
-- pouvait donc noter une boutique où il n'avait jamais commandé, noter la
-- commande d'un autre, ou noter avant même d'être livré — et rien dans les
-- notes affichées n'aurait permis de le voir.
--
-- Sur une place de marché, la note est ce qui décide du chiffre d'affaires
-- d'un boutiquier. La faille valait autant pour un concurrent malveillant
-- que pour un boutiquier s'auto-notant.
--
-- En trigger et non en policy : la vérification porte sur une AUTRE table
-- (orders), qu'une policy ne peut pas interroger sans risquer la récursion.

create or replace function public.guard_review()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_order record;
begin
  select user_id, merchant_id, driver_id, status
    into v_order
    from orders
   where id = new.order_id;

  if v_order is null then
    raise exception 'commande introuvable' using errcode = '23503';
  end if;

  -- L'admin corrige, modère, supprime : il n'est pas soumis à ces règles.
  if public.is_admin() then
    return new;
  end if;

  if v_order.user_id is distinct from new.user_id then
    raise exception 'on ne note que ses propres commandes' using errcode = '42501';
  end if;

  if v_order.status <> 'delivered' then
    raise exception 'on ne note qu''une commande livree' using errcode = '42501';
  end if;

  -- La boutique et le livreur notés sont ceux de la commande, pas ceux que
  -- le client indique : sinon il suffirait d'une seule commande livrée pour
  -- noter toutes les boutiques de la plateforme.
  new.merchant_id := v_order.merchant_id;
  new.driver_id   := v_order.driver_id;

  return new;
end $$;

drop trigger if exists trg_guard_review on reviews;
create trigger trg_guard_review
  before insert or update on reviews
  for each row execute function guard_review();

-- ---------------------------------------------------------------------
-- Les notes affichées
-- ---------------------------------------------------------------------

/*
 * Recalcule la note d'une boutique et d'un livreur après un avis.
 *
 * Recalcul complet plutôt qu'une moyenne mise à jour au fil de l'eau : une
 * moyenne incrémentale dérive dès qu'un avis est modifié ou supprimé, et
 * l'écart ne se voit jamais. Sur quelques milliers d'avis par boutique, le
 * coût est négligeable.
 *
 * La note par défaut reste 5,0 sans aucun avis — c'est ce que fait déjà le
 * schéma, et afficher 0 sur une boutique qui vient d'ouvrir la condamnerait.
 */
create or replace function public.refresh_ratings()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_merchant uuid := coalesce(new.merchant_id, old.merchant_id);
  v_driver   uuid := coalesce(new.driver_id, old.driver_id);
begin
  if v_merchant is not null then
    update merchants m
       set rating = coalesce((
             select round(avg(r.rating)::numeric, 1)
             from reviews r where r.merchant_id = v_merchant
           ), 5.0),
           rating_count = (
             select count(*) from reviews r where r.merchant_id = v_merchant
           )
     where m.id = v_merchant;
  end if;

  if v_driver is not null then
    update driver_profiles d
       set rating = coalesce((
             select round(avg(r.rating)::numeric, 1)
             from reviews r where r.driver_id = v_driver
           ), 5.0)
     where d.id = v_driver;
  end if;

  return null;
end $$;

drop trigger if exists trg_refresh_ratings on reviews;
create trigger trg_refresh_ratings
  after insert or update or delete on reviews
  for each row execute function refresh_ratings();

-- ---------------------------------------------------------------------
-- Adresses : une seule par défaut
-- ---------------------------------------------------------------------
-- Sans cela, deux adresses marquées par défaut donnent une commande livrée
-- au hasard de l'ordre des lignes — et le client ne comprend pas pourquoi.

create or replace function public.single_default_address()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_default then
    update addresses
       set is_default = false
     where user_id = new.user_id
       and id <> new.id
       and is_default;
  end if;
  return new;
end $$;

drop trigger if exists trg_single_default_address on addresses;
create trigger trg_single_default_address
  after insert or update of is_default on addresses
  for each row execute function single_default_address();

/*
 * Les adresses d'un client, la sienne par défaut en tête.
 *
 * La position revient en latitude/longitude séparées : le type `geography`
 * traverse PostgREST en hexadécimal WKB, que l'app devrait décoder elle-même
 * pour rien.
 */
create or replace function public.my_addresses()
returns table (
  id         uuid,
  label      text,
  text_hint  text,
  lat        double precision,
  lng        double precision,
  is_default boolean
)
language sql stable security definer set search_path = public as $$
  select a.id, a.label, a.text_hint,
         st_y(a.location::geometry), st_x(a.location::geometry),
         a.is_default
  from addresses a
  where a.user_id = auth.uid()
  order by a.is_default desc, a.created_at desc
$$;

/*
 * Enregistre une adresse. Renvoie son identifiant.
 *
 * À Niamey il n'y a pas d'adresse postale : `text_hint` porte l'essentiel
 * (« Yantala, derrière la pharmacie Al Nour ») et les coordonnées servent au
 * calcul de la zone et des frais.
 */
create or replace function public.save_address(
  p_label      text,
  p_text_hint  text,
  p_lat        double precision,
  p_lng        double precision,
  p_is_default boolean default false
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_premiere boolean;
begin
  if auth.uid() is null then
    raise exception 'authentification requise' using errcode = '42501';
  end if;

  -- La première adresse devient celle par défaut sans qu'on le demande :
  -- sinon le client en enregistre une et rien ne se pré-remplit.
  select not exists (select 1 from addresses where user_id = auth.uid())
    into v_premiere;

  insert into addresses (user_id, label, text_hint, location, is_default)
  values (
    auth.uid(),
    coalesce(nullif(trim(p_label), ''), 'Adresse'),
    p_text_hint,
    st_setsrid(st_point(p_lng, p_lat), 4326)::geography,
    p_is_default or v_premiere
  )
  returning id into v_id;

  return v_id;
end $$;

notify pgrst, 'reload schema';
