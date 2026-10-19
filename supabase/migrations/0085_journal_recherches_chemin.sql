-- =====================================================================
-- 0085 — Journal des recherches : chemin, temps de réponse, version
-- =====================================================================
-- Pour lire un avant/après dans les vraies recherches (revue du 19/10) :
--   chemin   : ce qui a trouvé — mots (exact), approche (fautes tolérées),
--              synonyme, rayon (catégorie nommée), sens (embeddings), aucun ;
--   duree_ms : le temps de la recherche (du tour entier pour l'assistant) ;
--   version  : le commit déployé (Railway), pour comparer deux versions.
-- Sans cette migration, le serveur note quand même le reste (journalRecherche.ts).

alter table public.recherches add column if not exists chemin text;
alter table public.recherches add column if not exists duree_ms integer;
alter table public.recherches add column if not exists version text;

-- Les chemins et la vitesse, par jour et par version.
create or replace view public.recherches_par_chemin as
select date_trunc('day', cree_le) as jour, version, source, coalesce(chemin, '?') as chemin,
       count(*) as recherches,
       count(*) filter (where ajoute_panier is not null) as mises_au_panier,
       percentile_cont(0.5) within group (order by duree_ms) as duree_mediane_ms,
       percentile_cont(0.95) within group (order by duree_ms) as duree_p95_ms
from public.recherches
group by 1, 2, 3, 4
order by 1 desc, recherches desc;

alter view public.recherches_par_chemin set (security_invoker = true);
revoke all on public.recherches_par_chemin from anon, authenticated;
