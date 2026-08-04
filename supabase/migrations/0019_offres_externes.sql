-- =====================================================================
-- 0019 — Les offres externes doivent pouvoir vivre plus d'une journée
-- =====================================================================
-- `compare_prices` réunit déjà les partenaires et les offres externes, mais
-- la table est restée vide : rien ne l'alimente.
--
-- L'obstacle était l'expiration. `expires_at` valait 24 h par défaut — le
-- rythme d'un moissonnage automatique. Or à Niamey les prix de la
-- concurrence se relèvent à la main : un prix saisi le lundi disparaissait
-- le mardi, et l'admin aurait dû tout ressaisir chaque jour. Trente jours
-- correspond à ce que dure réellement un prix affiché en boutique.
--
-- La purge, elle, existe depuis la 0002 : `purge_external_offers()` et son
-- cron nocturne suppriment les offres périmées depuis plus d'une semaine.
-- Rien à ajouter de ce côté.

alter table external_offers
  alter column expires_at set default now() + interval '30 days';

-- Trace de l'indexation, comme sur les produits : sans elle, impossible de
-- savoir si une offre est absente des comparaisons parce qu'elle n'a pas
-- d'embedding — `compare_prices` exige `embedding is not null` — ou parce
-- qu'elle ne correspond simplement pas à la recherche.
alter table external_offers add column if not exists embedded_at timestamptz;

-- Qui a saisi le prix. Un relevé de concurrence est une affirmation sur le
-- marché : quand un prix paraît faux, il faut pouvoir demander à quelqu'un.
alter table external_offers add column if not exists created_by uuid references profiles(id);

-- Les offres déjà en base gardent au moins trente jours devant elles. Il n'y
-- en a aucune aujourd'hui, mais la migration doit rester juste si on la
-- rejoue sur une base déjà remplie.
update external_offers
   set expires_at = now() + interval '30 days'
 where expires_at < now() + interval '30 days';

notify pgrst, 'reload schema';
