-- Les signalements : chaque fois qu'un client dit avoir un problème (mauvaise
-- commande, article manquant, paiement Nita bloqué, monnaie, livreur…),
-- l'assistant répond, et le problème arrive ici pour qu'un humain le règle.
--
-- Écrit par le serveur quand le cerveau comprend « aide » (routes/chat.ts) ;
-- lu et traité par l'admin (page Signalements).

create table if not exists public.signalements (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  conversation_id  uuid,
  -- La commande la plus récente du client au moment du message (48 h).
  order_id         uuid references public.orders (id) on delete set null,
  message          text not null check (length(message) between 1 and 2000),
  statut           text not null default 'ouvert' check (statut in ('ouvert', 'en_cours', 'regle')),
  reponse_admin    text check (length(reponse_admin) <= 2000),
  cree_le          timestamptz not null default now(),
  regle_le         timestamptz,
  regle_par        uuid references auth.users (id)
);

create index if not exists signalements_ouverts on public.signalements (statut, cree_le desc);

alter table public.signalements enable row level security;

-- Le client voit ses propres signalements ; l'admin voit et traite tout.
drop policy if exists signalements_client on public.signalements;
create policy signalements_client on public.signalements
  for select using (user_id = auth.uid());

drop policy if exists signalements_admin on public.signalements;
create policy signalements_admin on public.signalements
  for all using (public.is_admin()) with check (public.is_admin());
