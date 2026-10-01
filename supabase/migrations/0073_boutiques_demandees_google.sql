-- Le complément Google (01/10) : une boutique demandée que notre annuaire ne
-- connaît pas est cherchée sur Google. On ne garde que l'identifiant Google
-- du lieu (place_id, le seul champ que Google permet de conserver) : la
-- fois suivante, on le redemande directement, moins cher et toujours à jour.
-- Le nom, l'adresse et le numéro de Google ne sont JAMAIS enregistrés.

alter table public.boutiques_demandees
  add column if not exists google_place_id text check (length(google_place_id) <= 300),
  -- 'annuaire' (notre liste), 'google' (trouvée sur Google), 'inconnue'.
  add column if not exists trouvee text check (trouvee in ('annuaire', 'google', 'inconnue'));

create index if not exists boutiques_demandees_place on public.boutiques_demandees (nom_normalise)
  where google_place_id is not null;
