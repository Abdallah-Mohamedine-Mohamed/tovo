-- La carte de suivi : les positions du livreur, EN DIRECT.
--
-- L'app client s'abonne aux insertions de driver_locations pour sa
-- commande (Realtime, filtre order_id). Mais la table n'avait jamais été
-- ajoutée à la publication supabase_realtime — seule orders l'est (0051) :
-- l'abonnement s'ouvrait, et aucune position n'arrivait jamais. La moto
-- restait figée sur la position lue à l'ouverture (0069).
--
-- Qui voit quoi : Realtime applique la politique RLS de la table
-- (driver_locations_customer, 0004) — le client ne reçoit que les positions
-- de SA commande en cours.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'driver_locations'
  ) then
    alter publication supabase_realtime add table public.driver_locations;
  end if;
end $$;
