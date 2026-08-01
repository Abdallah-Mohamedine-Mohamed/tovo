-- =====================================================================
-- 0003 — Policies Storage
-- =====================================================================
-- À exécuter APRÈS avoir créé les trois buckets dans le dashboard :
--   products       (public)
--   search-images  (privé)
--   proofs         (privé)
--
-- Créer un bucket ne crée aucune policy : sans ce fichier, `products` est
-- lisible mais personne ne peut téléverser, et les deux buckets privés sont
-- totalement inaccessibles.
--
-- Convention de chemin, appliquée par les policies : le premier segment est
-- l'UUID du propriétaire.
--   search-images/{user_id}/{uuid}.jpg
--   proofs/{order_id}/{uuid}.jpg
--   products/{merchant_id}/{uuid}.jpg
-- =====================================================================

do $$
declare
  pol record;
begin
  for pol in
    select policyname from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname like 'tovo_%'
  loop
    execute format('drop policy if exists %I on storage.objects', pol.policyname);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- products — lecture publique, écriture par le boutiquier propriétaire
-- ---------------------------------------------------------------------
-- Le premier segment du chemin doit être l'id d'une boutique que
-- l'utilisateur possède. Sans ça, n'importe quel boutiquier pourrait
-- remplacer les photos d'un concurrent.

create policy tovo_products_read on storage.objects for select
  using (bucket_id = 'products');

create policy tovo_products_write on storage.objects for insert
  with check (
    bucket_id = 'products'
    and exists (
      select 1 from public.merchants m
      where m.owner_id = auth.uid()
        and m.id::text = (storage.foldername(name))[1]
    )
  );

create policy tovo_products_update on storage.objects for update
  using (
    bucket_id = 'products'
    and exists (
      select 1 from public.merchants m
      where m.owner_id = auth.uid()
        and m.id::text = (storage.foldername(name))[1]
    )
  );

create policy tovo_products_delete on storage.objects for delete
  using (
    bucket_id = 'products'
    and exists (
      select 1 from public.merchants m
      where m.owner_id = auth.uid()
        and m.id::text = (storage.foldername(name))[1]
    )
  );

-- ---------------------------------------------------------------------
-- search-images — strictement privé
-- ---------------------------------------------------------------------
-- L'utilisateur téléverse une photo de ce qu'il cherche, le backend la lit
-- avec la service_role pour l'analyse Vision. Personne d'autre n'y accède :
-- une photo prise chez soi en dit long sur son auteur.

create policy tovo_search_images_own on storage.objects for select
  using (
    bucket_id = 'search-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy tovo_search_images_upload on storage.objects for insert
  with check (
    bucket_id = 'search-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy tovo_search_images_delete on storage.objects for delete
  using (
    bucket_id = 'search-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------
-- proofs — preuve de livraison
-- ---------------------------------------------------------------------
-- Écrite par le livreur assigné, lue par le client destinataire et par le
-- livreur. Le chemin est indexé par order_id, pas par user_id : la photo
-- appartient à la commande, pas à celui qui l'a prise.

create policy tovo_proofs_upload on storage.objects for insert
  with check (
    bucket_id = 'proofs'
    and exists (
      select 1 from public.orders o
      where o.id::text = (storage.foldername(name))[1]
        and o.driver_id = auth.uid()
    )
  );

create policy tovo_proofs_read on storage.objects for select
  using (
    bucket_id = 'proofs'
    and exists (
      select 1 from public.orders o
      where o.id::text = (storage.foldername(name))[1]
        and (o.user_id = auth.uid() or o.driver_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------
-- Purge des images de recherche
-- ---------------------------------------------------------------------
-- Elles n'ont d'utilité que le temps d'un tour de conversation. Les garder
-- serait accumuler des photos privées sans raison.

create or replace function public.purge_search_images()
returns void language sql security definer set search_path = public as $$
  delete from storage.objects
  where bucket_id = 'search-images'
    and created_at < now() - interval '24 hours';
$$;

select cron.schedule(
  'purge-search-images',
  '29 4 * * *',
  $$select public.purge_search_images()$$
);
