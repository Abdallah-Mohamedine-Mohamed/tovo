-- 1. Les lieux de Niamey (OpenStreetMap, licence ODbL — attribution :
--    « © les contributeurs d'OpenStreetMap »).
--
-- À Niamey, l'adresse postale n'existe pas : on dit « à Yantala, près de la
-- pharmacie X » ou « derrière le marché de Bobiel ». Cette table donne à Tovo
-- les quartiers, rues et repères (pharmacies, marchés, mosquées, écoles,
-- stations…) avec leur position, pour comprendre une adresse dite, placer une
-- boutique et, plus tard, dessiner la carte de suivi.
--
-- Rempli par backend/scripts/lieux/importer.ts depuis backend/data/lieux-niamey.json.

create table if not exists public.lieux (
  id             text primary key,               -- « osm:node/123 »
  nom            text not null,
  nom_normalise  text not null,                   -- minuscules, sans accents
  genre          text not null,                   -- quartier, rue, pharmacie, marché…
  quartier       text,                            -- le quartier le plus proche
  lat            double precision not null,
  lng            double precision not null,
  source         text not null default 'osm',
  maj_le         timestamptz not null default now()
);

create index if not exists lieux_genre on public.lieux (genre);
create extension if not exists pg_trgm;
create index if not exists lieux_nom_trgm on public.lieux using gin (nom_normalise gin_trgm_ops);

alter table public.lieux enable row level security;

-- Des repères publics : tout le monde peut les lire, seul le serveur écrit.
drop policy if exists lieux_lecture on public.lieux;
create policy lieux_lecture on public.lieux for select using (true);

-- 2. Banc IA : des phrases venues de jeux de données publics (MASSIVE
--    d'Amazon, licence CC BY 4.0), gardées seulement si deux IA fortes
--    s'accordent sur leur sens.
alter table public.banc_cas drop constraint if exists banc_cas_origine_check;
alter table public.banc_cas add constraint banc_cas_origine_check
  check (origine in ('reel', 'synthetique', 'piege', 'public'));
