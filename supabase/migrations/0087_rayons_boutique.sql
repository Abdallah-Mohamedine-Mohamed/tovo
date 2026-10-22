-- =====================================================================
-- 0087 — Les catégories PROPRES à une boutique (Niger Beauté, 22/10)
-- =====================================================================
-- Une grande boutique (Niger Beauté : plus de 700 produits) ne s'affiche
-- plus comme une carte de restaurant, rayon après rayon : sa page ne montre
-- que ses catégories (une icône, un nom), et une catégorie ouvre ses
-- articles, filtrés sur place par des pastilles (ses sous-catégories).
--
-- Ces catégories appartiennent à LA boutique : elles ne remplacent pas les
-- catégories communes de Tovo (products.category_id), qui servent toujours à
-- l'accueil et à la recherche. Toutes les autres boutiques gardent leur page
-- actuelle : `merchants.affichage` vaut « carte » par défaut.
--
-- Rempli par backend/scripts/niger-beaute/rayons.ts.

alter table public.merchants add column if not exists affichage text not null default 'carte';
alter table public.merchants drop constraint if exists merchants_affichage_check;
alter table public.merchants add constraint merchants_affichage_check
  check (affichage in ('carte', 'categories'));

create table if not exists public.rayons_boutique (
  merchant_id  uuid not null references public.merchants(id) on delete cascade,
  cle          text not null check (cle ~ '^[a-z0-9-]{2,60}$'),
  nom          text not null check (length(nom) between 2 and 40),
  icone_url    text,
  ordre        integer not null default 0,
  -- L'ordre des pastilles ; une sous-catégorie absente d'ici passe à la fin.
  sous_rayons  text[] not null default '{}',
  primary key (merchant_id, cle)
);

alter table public.rayons_boutique enable row level security;
drop policy if exists rayons_boutique_lecture on public.rayons_boutique;
create policy rayons_boutique_lecture on public.rayons_boutique
  for select using (true);
drop policy if exists rayons_boutique_admin on public.rayons_boutique;
create policy rayons_boutique_admin on public.rayons_boutique
  for all using (public.is_admin()) with check (public.is_admin());

-- La catégorie et la sous-catégorie du produit DANS sa boutique (clé de
-- rayons_boutique, nom de la pastille). Nulles ailleurs.
alter table public.products add column if not exists rayon_boutique text;
alter table public.products add column if not exists sous_rayon text;
create index if not exists products_rayon_boutique_idx
  on public.products (merchant_id, rayon_boutique) where rayon_boutique is not null;
