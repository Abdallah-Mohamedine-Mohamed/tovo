-- =====================================================================
-- 0084 — Ce que cherchent les clients, et le dictionnaire des synonymes
-- =====================================================================
-- Jusqu'ici, les recherches des clients ne laissaient aucune trace : les
-- bancs (scripts/recherche/) mesurent ce que NOUS imaginons qu'ils tapent.
-- Une fois Tovo lancé, ce sont leurs vraies recherches qui font foi.
--
-- 1. `recherches` : chaque recherche tapée (barre de recherche, assistant),
--    son nombre de résultats, les produits montrés, et si l'un d'eux a été
--    mis au panier ensuite. Écrite par le serveur seul (clé serveur) ;
--    personne ne la lit depuis l'application.
--
-- 2. `synonymes_recherche` : « tente ceremonie » → « chapiteau ». Appliqué
--    à la phrase du client SEULEMENT quand elle ne trouve rien telle quelle,
--    et retenu seulement si la phrase réécrite trouve EXACTEMENT
--    (backend/src/services/synonymes.ts) : un synonyme ne peut qu'ajouter
--    des résultats, jamais en retirer ni en reclasser. La règle « tous les
--    mots » reste entière. Expressions sans accents ni majuscules, ni mots
--    vides (« de », « pour », « les » sont déjà retirés de la phrase) ; un
--    synonyme remplace, il ne retire jamais un mot.
--
-- 3. Deux vues à lire dans Supabase (éditeur de tables) chaque semaine :
--    `recherches_sans_resultat` et `recherches_sans_suite`.

create table if not exists public.recherches (
  id              bigint generated always as identity primary key,
  cree_le         timestamptz not null default now(),
  user_id         uuid references public.profiles(id) on delete set null,
  source          text not null check (source in ('barre', 'recherche', 'assistant')),
  phrase          text not null,          -- ce que le client a tapé
  requete         text not null,          -- ce qui a été cherché (normalisé)
  synonyme        text,                   -- la requête réécrite, si un synonyme a servi
  type_resultat   text,                   -- exact | similar
  total           integer not null,
  produits        uuid[] not null default '{}',  -- les produits montrés, dans l'ordre
  ajoute_panier   uuid                    -- le produit montré mis ensuite au panier
);
create index if not exists recherches_cree_le on public.recherches (cree_le desc);
create index if not exists recherches_user on public.recherches (user_id, cree_le desc);
alter table public.recherches enable row level security;
-- Aucune règle : seule la clé serveur lit et écrit.

create table if not exists public.synonymes_recherche (
  expression    text primary key check (expression = lower(expression)),
  -- Jamais vide : retirer un mot fausse (« location voiture » → « voiture »).
  remplacement  text not null check (btrim(remplacement) <> ''),
  note          text,
  actif         boolean not null default true,
  cree_le       timestamptz not null default now()
);
alter table public.synonymes_recherche enable row level security;

-- Premières entrées (19/10). Les autres ratés du banc des clients trouvent
-- déjà, ou visent des produits indisponibles (chapiteau, tables) : rien à
-- ajouter. Le reste viendra des vraies recherches.
insert into public.synonymes_recherche (expression, remplacement, note) values
  ('tente ceremonie', 'chapiteau', 'tente pour cérémonie (mots vides déjà retirés)'),
  ('mariage',         'ceremonie', 'location de tables pour mariage : les tables portent « cérémonie »')
on conflict (expression) do nothing;

-- Les recherches qui n'ont rien donné, regroupées : la liste de travail.
create or replace view public.recherches_sans_resultat as
select lower(phrase) as phrase, count(*) as fois, count(distinct user_id) as clients,
       max(cree_le) as derniere_fois
from public.recherches
where total = 0
group by lower(phrase)
order by fois desc, derniere_fois desc;

-- Des résultats, mais ni panier ni commande d'un produit montré dans les
-- deux heures : le client n'a sans doute pas trouvé ce qu'il voulait.
create or replace view public.recherches_sans_suite as
select lower(r.phrase) as phrase, count(*) as fois, count(distinct r.user_id) as clients,
       max(r.cree_le) as derniere_fois
from public.recherches r
where r.total > 0 and r.ajoute_panier is null
  and not exists (
    select 1 from public.orders o join public.order_items i on i.order_id = o.id
    where o.user_id = r.user_id and o.placed_at between r.cree_le and r.cree_le + interval '2 hours'
      and i.product_id = any (r.produits)
  )
group by lower(r.phrase)
order by fois desc, derniere_fois desc;

-- Les vues lisent avec les droits de l'appelant : rien d'exposé par l'API.
alter view public.recherches_sans_resultat set (security_invoker = true);
alter view public.recherches_sans_suite set (security_invoker = true);
revoke all on public.recherches, public.synonymes_recherche,
  public.recherches_sans_resultat, public.recherches_sans_suite from anon, authenticated;
