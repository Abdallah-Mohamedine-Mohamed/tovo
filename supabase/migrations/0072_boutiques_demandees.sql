-- Les boutiques que les clients demandent et qui ne sont PAS sur Tovo
-- (« de la viande chez Tchos »). Chaque demande est notée ici par le serveur
-- (services/catalogue.ts, enseigneHorsTovo) ; l'admin les voit regroupées par
-- nom, les plus demandées d'abord : c'est la liste de prospection.

create table if not exists public.boutiques_demandees (
  id             uuid primary key default gen_random_uuid(),
  -- Tel que le client l'a écrit (« Tchos »), et réduit pour regrouper
  -- (« tchos ») : minuscules, sans accents ni ponctuation.
  nom            text not null check (length(nom) between 1 and 120),
  nom_normalise  text not null check (length(nom_normalise) between 1 and 120),
  -- Ce qu'il voulait y acheter (« de la viande »), s'il l'a dit.
  article        text check (length(article) <= 200),
  cree_le        timestamptz not null default now()
);

create index if not exists boutiques_demandees_nom on public.boutiques_demandees (nom_normalise, cree_le desc);

alter table public.boutiques_demandees enable row level security;

-- Écrite par le serveur (clé de service, qui passe outre la RLS) ; seul
-- l'admin la lit.
drop policy if exists boutiques_demandees_admin on public.boutiques_demandees;
create policy boutiques_demandees_admin on public.boutiques_demandees
  for all using (public.is_admin()) with check (public.is_admin());
