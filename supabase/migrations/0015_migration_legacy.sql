-- =====================================================================
-- 0015 — Ce qu'il manque pour reprendre les données de 6ammart
-- =====================================================================
-- La migration doit pouvoir être relancée sans créer de doublons : on
-- s'interrompra forcément au moins une fois sur 2 000 produits et 2 300
-- comptes. Le repère de reprise est l'identifiant d'origine, déjà présent
-- sur profiles, merchants et products — il manquait sur les catégories et
-- les zones.

alter table categories      add column if not exists legacy_id text;
alter table delivery_zones  add column if not exists legacy_id text;

-- Unicité en index partiel : les catégories créées plus tard depuis l'admin
-- n'ont pas d'origine 6ammart, et plusieurs NULL ne doivent pas se gêner.
create unique index if not exists idx_categories_legacy
  on categories(legacy_id) where legacy_id is not null;
create unique index if not exists idx_zones_legacy
  on delivery_zones(legacy_id) where legacy_id is not null;

-- ---------------------------------------------------------------------
-- Bucket des visuels de catalogue gérés par l'admin
-- ---------------------------------------------------------------------
-- Les images de catégories n'appartiennent à aucune boutique : elles ne
-- peuvent pas aller dans le bucket `products`, dont la policy d'écriture
-- exige que le premier dossier soit l'id d'une boutique que l'on possède.

insert into storage.buckets (id, name, public)
values ('catalog', 'catalog', true)
on conflict (id) do nothing;

do $$
begin
  execute 'drop policy if exists tovo_catalog_read on storage.objects';
  execute 'drop policy if exists tovo_catalog_write on storage.objects';
  execute 'drop policy if exists tovo_catalog_update on storage.objects';
  execute 'drop policy if exists tovo_catalog_delete on storage.objects';
end $$;

create policy tovo_catalog_read on storage.objects for select
  using (bucket_id = 'catalog');

-- Écriture réservée à l'admin. Le chargement de migration passe par la clé
-- de service, qui ne traverse pas les policies.
create policy tovo_catalog_write on storage.objects for insert
  with check (bucket_id = 'catalog' and public.is_admin());

create policy tovo_catalog_update on storage.objects for update
  using (bucket_id = 'catalog' and public.is_admin());

create policy tovo_catalog_delete on storage.objects for delete
  using (bucket_id = 'catalog' and public.is_admin());

notify pgrst, 'reload schema';
