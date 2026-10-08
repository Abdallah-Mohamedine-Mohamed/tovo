-- Les catégories des commerces relevés sur le terrain (08/10) : les 12 de
-- l'annuaire ne suffisent pas. Un livreur peut en PROPOSER une nouvelle (il
-- l'utilise aussitôt) ; l'admin la valide, la renomme, ou la rattache à un
-- type de l'annuaire pour la recherche des clients (« Friperie » → vêtements).
-- Un commerce peut avoir plusieurs catégories. L'admin peut aussi corriger
-- tout ce qu'un livreur a envoyé, photo comprise. Suppose la migration 0076.

create table if not exists public.categories_commerce (
  slug         text primary key check (slug ~ '^[a-z0-9-]{2,60}$'),
  libelle      text not null check (length(libelle) between 2 and 60),
  -- Le type de l'annuaire auquel elle se rattache (recherche des clients).
  type         text check (type in ('supermarche', 'marche', 'boucherie', 'boulangerie', 'beaute',
                 'electronique', 'vetements', 'quincaillerie', 'restaurant', 'grillades', 'pharmacie', 'boutique')),
  statut       text not null default 'valide' check (statut in ('propose', 'valide')),
  propose_par  uuid references public.profiles(id),
  cree_le      timestamptz not null default now()
);

insert into public.categories_commerce (slug, libelle, type) values
  ('boutique', 'Boutique', 'boutique'),
  ('supermarche', 'Supermarché', 'supermarche'),
  ('restaurant', 'Restaurant', 'restaurant'),
  ('grillades', 'Grillades', 'grillades'),
  ('vetements', 'Vêtements', 'vetements'),
  ('beaute', 'Beauté', 'beaute'),
  ('electronique', 'Téléphones', 'electronique'),
  ('pharmacie', 'Pharmacie', 'pharmacie'),
  ('boulangerie', 'Boulangerie', 'boulangerie'),
  ('boucherie', 'Boucherie', 'boucherie'),
  ('quincaillerie', 'Quincaillerie', 'quincaillerie'),
  ('marche', 'Marché', 'marche')
on conflict (slug) do nothing;

alter table public.categories_commerce enable row level security;
drop policy if exists categories_commerce_lecture on public.categories_commerce;
create policy categories_commerce_lecture on public.categories_commerce
  for select using (statut = 'valide' or propose_par = auth.uid() or public.is_admin());
drop policy if exists categories_commerce_admin on public.categories_commerce;
create policy categories_commerce_admin on public.categories_commerce
  for all using (public.is_admin()) with check (public.is_admin());

-- Les fiches : plusieurs catégories ; le type de l'annuaire en découle.
alter table public.commerces_terrain drop constraint if exists commerces_terrain_type_check;
alter table public.commerces_terrain alter column type drop not null;
alter table public.commerces_terrain add column if not exists categories text[] not null default '{}';
update public.commerces_terrain set categories = array[type] where categories = '{}' and type is not null;

-- L'admin remplace une photo : il écrit dans le stockage « terrain ».
drop policy if exists terrain_admin_ecrit on storage.objects;
create policy terrain_admin_ecrit on storage.objects
  for insert with check (bucket_id = 'terrain' and public.is_admin());
drop policy if exists terrain_admin_modifie on storage.objects;
create policy terrain_admin_modifie on storage.objects
  for update using (bucket_id = 'terrain' and public.is_admin());
drop policy if exists terrain_admin_supprime on storage.objects;
create policy terrain_admin_supprime on storage.objects
  for delete using (bucket_id = 'terrain' and public.is_admin());
