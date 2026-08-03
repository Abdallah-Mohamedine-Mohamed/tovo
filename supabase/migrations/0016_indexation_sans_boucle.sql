-- =====================================================================
-- 0016 — L'indexation ne doit pas se réveiller elle-même
-- =====================================================================
-- Symptôme : 2 700 embeddings calculés, mais 50 produits indexés. Les 2 051
-- autres n'ont jamais été vus.
--
-- Cause : `products_to_embed()` sélectionne les produits dont
-- `embedded_at < updated_at`, triés par `updated_at desc`. Quand l'indexeur
-- écrit l'embedding, le trigger générique `set_updated_at` repousse
-- `updated_at` à now() — forcément après le `embedded_at` que Node a calculé
-- avant d'envoyer sa requête. Le produit qu'on vient d'indexer redevient donc
-- éligible, et le tri le remonte en tête : l'indexeur reprend le même lot de
-- 50 indéfiniment sans jamais atteindre le reste du catalogue.
--
-- En production, l'indexeur passe toutes les 5 minutes. Rien n'aurait
-- signalé la panne : la recherche fonctionnait sur les 50 premiers produits,
-- le quota d'embeddings se consommait en continu, et les nouveautés des
-- boutiquiers ne devenaient jamais cherchables.
--
-- Correctif : réindexer n'est pas modifier un produit. Seul l'indexeur écrit
-- `embedded_at` ; quand cette colonne change, on laisse `updated_at` où il
-- est. Un boutiquier qui corrige une fiche ne touche jamais à `embedded_at`,
-- son `updated_at` continue donc de bouger normalement — et son produit sera
-- bien réindexé.

create or replace function public.set_updated_at_products()
returns trigger language plpgsql as $$
begin
  if new.embedded_at is distinct from old.embedded_at then
    new.updated_at := old.updated_at;
  else
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_products_updated on products;
create trigger trg_products_updated before update on products
  for each row execute function set_updated_at_products();

-- ---------------------------------------------------------------------
-- Réparation des produits déjà indexés
-- ---------------------------------------------------------------------
-- Ils portent tous un `updated_at` postérieur de quelques millisecondes à
-- leur `embedded_at`, uniquement à cause de la boucle. Leur embedding est à
-- jour : il a été calculé sur le texte courant. On aligne les deux dates
-- pour ne pas les recalculer une fois de plus.
--
-- Cet UPDATE déclenche le trigger que l'on vient de corriger : il modifie
-- `embedded_at`, donc `updated_at` reste en place. C'est bien ce qu'on veut.

update products
   set embedded_at = updated_at
 where embedding is not null
   and embedded_at is not null
   and embedded_at < updated_at;

notify pgrst, 'reload schema';
