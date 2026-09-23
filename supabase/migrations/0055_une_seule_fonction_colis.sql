-- =====================================================================
-- 0055 — Une seule version de place_courier_order
-- =====================================================================
-- 0033 a ajouté deux paramètres (contacts) avec `create or replace`. En
-- Postgres, changer la liste des paramètres ne REMPLACE pas la fonction :
-- ça en crée une seconde. La base gardait donc l'ancienne à 11 paramètres
-- à côté de la bonne à 13.
--
-- Tout appel qui ne nommait pas les 13 paramètres échouait : PostgREST ne
-- sait pas choisir entre les deux (PGRST203), et l'app recevait une 500.
-- C'est ce qui cassait « Je veux un livreur » dans les scénarios.
--
-- On supprime l'ancienne ; la version à 13 paramètres (0053) reste seule.

drop function if exists public.place_courier_order(
  uuid, text, double precision, double precision,
  text, double precision, double precision,
  parcel_size, payment_method, timestamptz, text
);

notify pgrst, 'reload schema';
