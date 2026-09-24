import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * Une boutique est ouverte si son interrupteur est sur « ouvert » ET qu'elle
 * est dans ses horaires du jour — la même règle que la base
 * (merchant_open_now, migration 0021).
 *
 * Plusieurs listes ne lisaient que l'interrupteur : Explorer affichait
 * « Ouverte » sur des boutiques hors horaires, et le client ne découvrait la
 * vérité qu'en entrant (panier bloqué, « la boutique est fermée »).
 *
 * Calculé ici en une seule requête pour toute la liste, plutôt qu'un appel à
 * la base par boutique.
 */

interface Horaire {
  merchant_id: string;
  day: number;
  opens_at: string;
  closes_at: string;
}

/** Jour (0 = dimanche) et heure « HH:MM:SS » à Niamey : UTC+1, sans heure d'été. */
export function maintenantANiamey(date = new Date()): { jour: number; heure: string } {
  const niamey = new Date(date.getTime() + 60 * 60 * 1000);
  return { jour: niamey.getUTCDay(), heure: niamey.toISOString().slice(11, 19) };
}

/** La règle, pour une boutique et ses horaires. */
export function ouverteMaintenant(
  interrupteur: boolean,
  horaires: Array<Pick<Horaire, 'day' | 'opens_at' | 'closes_at'>>,
  date = new Date(),
): boolean {
  if (!interrupteur) return false;
  // Sans horaires déclarés, l'interrupteur fait foi (comme en base).
  if (horaires.length === 0) return true;
  const { jour, heure } = maintenantANiamey(date);
  return horaires.some((h) => h.day === jour && h.opens_at <= heure && heure <= h.closes_at);
}

/** Corrige `is_open` d'une liste de boutiques selon leurs horaires. */
export async function avecOuvertureReelle<T extends { id: string; is_open: boolean }>(
  db: SupabaseClient,
  boutiques: T[],
): Promise<T[]> {
  const aVerifier = boutiques.filter((b) => b.is_open).map((b) => b.id);
  if (aVerifier.length === 0) return boutiques;
  let data: unknown[] | null = null;
  try {
    const reponse = await db
      .from('merchant_hours')
      .select('merchant_id, day, opens_at, closes_at')
      .in('merchant_id', aVerifier);
    if (reponse.error) return boutiques;
    data = reponse.data;
  } catch {
    // Horaires illisibles : on garde l'interrupteur plutôt que de tout fermer.
    return boutiques;
  }
  const parBoutique = new Map<string, Horaire[]>();
  for (const h of (data ?? []) as Horaire[]) {
    parBoutique.set(h.merchant_id, [...(parBoutique.get(h.merchant_id) ?? []), h]);
  }
  return boutiques.map((b) =>
    b.is_open ? { ...b, is_open: ouverteMaintenant(true, parBoutique.get(b.id) ?? []) } : b,
  );
}
