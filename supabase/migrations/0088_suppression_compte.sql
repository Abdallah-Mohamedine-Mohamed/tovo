-- =====================================================================
-- 0088 — Supprimer son compte depuis l'application (02/11)
-- =====================================================================
-- Apple et Google l'exigent : un client doit pouvoir supprimer son compte
-- lui-même, depuis l'application. Jusqu'ici c'était impossible : une seule
-- commande passée bloquait la suppression (orders.user_id … on delete
-- restrict).
--
-- Les commandes passées RESTENT — ce sont les traces comptables des
-- boutiques et des livreurs — mais sans personne derrière : user_id devient
-- nul à la suppression, et le serveur efface avant le repère d'adresse, la
-- note et la photo de livraison (routes/compte.ts). Tout le reste (adresses,
-- conversations, panier, jetons de notification…) part déjà en cascade avec
-- le profil.

alter table public.orders alter column user_id drop not null;
alter table public.orders drop constraint if exists orders_user_id_fkey;
alter table public.orders add constraint orders_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete set null;

-- Le registre des suppressions : QUAND, et combien de commandes étaient
-- rattachées. Aucune donnée sur la personne — c'est tout l'objet.
create table if not exists public.comptes_supprimes (
  id            bigint generated always as identity primary key,
  supprime_le   timestamptz not null default now(),
  commandes     integer not null default 0
);
alter table public.comptes_supprimes enable row level security;
drop policy if exists comptes_supprimes_admin on public.comptes_supprimes;
create policy comptes_supprimes_admin on public.comptes_supprimes
  for select using (public.is_admin());
