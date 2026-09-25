import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * Les zones se chevauchent : « Niamey » couvre toute la ville, Yantala ou le
 * Plateau en sont des quartiers. Une commande prend la zone la plus fine de
 * son point de collecte ; un livreur est souvent rattaché à la ville entière.
 * Comparer les deux par égalité écartait ce livreur de toutes les commandes
 * de quartier (migration 0063).
 *
 * Renvoie un filtre : un livreur de la zone donnée peut-il servir cette
 * commande ?
 */
export async function filtreDeZone(
  db: SupabaseClient,
  zoneCommande: string | null | undefined,
): Promise<(zoneLivreur: string | null | undefined) => boolean> {
  if (zoneCommande == null) return () => true;

  const { data, error } = await db.rpc('zones_englobantes', { p_zone: zoneCommande });
  // Migration 0063 pas encore appliquée : l'ancienne règle (égalité), plutôt
  // que de ne prévenir personne.
  const couvrantes = new Set<string>(
    error || !Array.isArray(data)
      ? [zoneCommande]
      : data.map((ligne: unknown) =>
          typeof ligne === 'string' ? ligne : String((ligne as Record<string, unknown>).zones_englobantes)),
  );
  couvrantes.add(zoneCommande);

  return (zoneLivreur) => zoneLivreur == null || couvrantes.has(zoneLivreur);
}
