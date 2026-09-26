import type { SupabaseClient } from '@supabase/supabase-js';
import { envelope, orderTracking } from '../components/builders.js';
import { queueDispatch } from './dispatch.js';

/**
 * « Je veux un livreur » — la commande part, sans formulaire.
 *
 * Au Niger on n'écrit pas une adresse : on appelle un livreur, il vient, et
 * le reste se règle au téléphone. Tout ce que le système exige, il l'a déjà :
 * la position du client (le téléphone la connaît) et son numéro (Tovo le
 * connaît). La destination est facultative (voir migration 0053).
 */

export interface OffreVille {
  /** Tarif ville fixe, ou null si la base ne le fournit pas encore. */
  prix: number | null;
  /** Délai annoncé : « un livreur vous appelle dans les N minutes ». */
  minutes: number;
}

const DELAI_PAR_DEFAUT = 7;

export async function offreVille(db: SupabaseClient): Promise<OffreVille> {
  try {
    const { data, error } = await db.rpc('courier_city_offer');
    if (error || !data) return { prix: null, minutes: DELAI_PAR_DEFAUT };
    const offre = data as { price?: number; callback_minutes?: number };
    return {
      prix: typeof offre.price === 'number' ? offre.price : null,
      minutes: typeof offre.callback_minutes === 'number' ? offre.callback_minutes : DELAI_PAR_DEFAUT,
    };
  } catch {
    return { prix: null, minutes: DELAI_PAR_DEFAUT };
  }
}

export async function messageLivreurEnRoute(db: SupabaseClient, nita = false): Promise<string> {
  const { minutes } = await offreVille(db);
  const base = `C’est parti. Un livreur vous appelle dans les **${minutes} minutes**.`;
  // Sans code ni jargon : la demande attend le client dans MyNita.
  return nita ? `${base} Confirmez le paiement dans MyNita, ou payez au livreur.` : base;
}

export { demandeUnLivreur } from '../ai/intents.js';

interface CommandeLivreur {
  clientOrderId: string;
  position: { lat: number; lng: number };
  journal?: (cause: unknown, orderId: string) => void;
}

/**
 * Passe la commande et renvoie l'enveloppe à afficher.
 *
 * Idempotente par `clientOrderId` (l'identifiant du message) : un rejeu
 * réseau ne fait pas venir deux livreurs. Et si une course est déjà en
 * cours, on la montre au lieu d'en créer une seconde — « je veux un
 * livreur » dit deux fois, c'est de l'impatience, pas deux colis.
 */
export async function commanderUnLivreur(db: SupabaseClient, commande: CommandeLivreur) {
  const { data: enCours } = await db
    .from('orders')
    .select('id')
    .eq('type', 'courier')
    .not('status', 'in', '(delivered,cancelled)')
    .gte('placed_at', new Date(Date.now() - 2 * 3600_000).toISOString())
    .order('placed_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (enCours?.id) {
    const suivi = await db.rpc('order_tracking', { p_order_id: enCours.id });
    return envelope(
      'Un livreur est déjà en route pour vous. Il vous appelle très vite.',
      suivi.data ? [orderTracking(suivi.data as Record<string, unknown>)] : [],
    );
  }

  const { data: orderId, error } = await db.rpc('place_courier_order', {
    p_client_order_id: commande.clientOrderId,
    p_pickup_hint: 'Position du client',
    p_pickup_lat: commande.position.lat,
    p_pickup_lng: commande.position.lng,
    p_dropoff_hint: null,
    p_dropoff_lat: null,
    p_dropoff_lng: null,
    // TOUS les paramètres, explicitement : la base garde une ancienne
    // version à 11 paramètres de cette fonction, et avec un appel partiel
    // PostgREST ne sait pas laquelle choisir (PGRST203 → 500). La migration
    // 0055 supprime l'ancienne ; ceci reste juste avec ou sans elle.
    p_parcel: 'small',
    p_payment: 'cash',
    p_scheduled_for: null,
    p_parcel_note: null,
    p_dropoff_contact: null,
    p_pickup_contact: null,
  });
  if (error) throw error;

  // Immédiat : c'est tout l'intérêt. Un échec de file ne doit pas faire
  // échouer une commande déjà enregistrée : on le signale, comme
  // POST /orders, et la commande reste visible des livreurs.
  queueDispatch(orderId as string).catch((cause) => commande.journal?.(cause, orderId as string));

  const suivi = await db.rpc('order_tracking', { p_order_id: orderId });
  return envelope(
    await messageLivreurEnRoute(db),
    suivi.data ? [orderTracking(suivi.data as Record<string, unknown>)] : [],
  );
}
