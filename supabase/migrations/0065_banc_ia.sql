-- Le banc IA en base : l'examen du cerveau qui grandit en continu.
--
-- Chaque cas est une phrase de client et ce qu'elle veut dire (l'intention).
-- Trois origines :
--   - 'reel'        : une vraie phrase de client, récoltée par la boucle ;
--   - 'synthetique' : écrite par un modèle fort qui imite un client, gardée
--                     seulement si un SECOND modèle, d'une autre famille et
--                     sans voir la première étiquette, est d'accord ;
--   - 'piege'       : écrite exprès pour faire tomber le cerveau.
--
-- Statuts :
--   - 'a_valider' : l'étiqueteur et le cerveau ne sont pas d'accord — un
--                   humain tranche dans l'admin (page « Qualité de l'IA ») ;
--   - 'valide'    : fait partie de l'examen ;
--   - 'rejete'    : écarté (phrase inutile, ambiguë, hors sujet).
--
-- Écrit par la boucle (clé serveur, scripts/banc-ia/boucle.ts), lu et
-- tranché par l'admin.

create table if not exists public.banc_cas (
  id              uuid primary key default gen_random_uuid(),
  texte           text not null check (length(texte) between 1 and 500),
  -- Le dernier message de Tovo, quand la phrase y répond (« Yantala. »).
  avant           text,
  attendu         text not null,
  origine         text not null check (origine in ('reel', 'synthetique', 'piege')),
  statut          text not null default 'a_valider'
                  check (statut in ('a_valider', 'valide', 'rejete')),
  -- Ce que chacun a répondu, pour que l'humain voie le désaccord.
  etiqueteur      text,
  juge            text,
  cerveau         text,
  -- Personnage et scénario d'une phrase synthétique, ou raison du doute.
  note            text,
  -- Phrase normalisée : une même phrase n'entre qu'une fois.
  cle             text not null unique,
  cree_le         timestamptz not null default now(),
  tranche_le      timestamptz,
  tranche_par     uuid references auth.users (id)
);

create index if not exists banc_cas_statut on public.banc_cas (statut, cree_le desc);

alter table public.banc_cas enable row level security;

drop policy if exists banc_cas_admin on public.banc_cas;
create policy banc_cas_admin on public.banc_cas
  for all using (public.is_admin()) with check (public.is_admin());

-- Le rapport de chaque passage : ce qui a été récolté, écrit, et le score.
-- Le passage suivant récolte à partir de `cree_le` du dernier.
create table if not exists public.banc_passages (
  id          uuid primary key default gen_random_uuid(),
  rapport     jsonb not null,
  cree_le     timestamptz not null default now()
);

create index if not exists banc_passages_date on public.banc_passages (cree_le desc);

alter table public.banc_passages enable row level security;

drop policy if exists banc_passages_admin on public.banc_passages;
create policy banc_passages_admin on public.banc_passages
  for select using (public.is_admin());

-- Réglages de la boucle, modifiables dans l'admin (page Qualité de l'IA) :
-- le serveur lit ces valeurs à chaque minute (backend/src/services/bancIa.ts).
alter table public.platform_settings
  add column if not exists banc_ia_actif boolean not null default true,
  add column if not exists banc_ia_intervalle_min integer not null default 30
    check (banc_ia_intervalle_min between 10 and 1440),
  add column if not exists banc_ia_phrases integer not null default 30
    check (banc_ia_phrases between 0 and 200);
