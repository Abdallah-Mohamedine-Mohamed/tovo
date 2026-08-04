import { env } from '../config/env.js';
import { serviceClient } from './supabase.js';
import { notifierBoutique } from './orderNotifications.js';
import {
  annulerAchat,
  creerAchat,
  statutAchat,
  versTelephoneNita,
  NitaError,
  STATUT_ACHAT,
} from './nita.js';

/**
 * Le paiement mobile, du côté de Tovo.
 *
 * Le principe qui gouverne ce fichier : **c'est Nita qui dit si c'est payé**,
 * jamais le message reçu. Le callback de Nita n'est signé par rien ; il sert
 * seulement à savoir qu'il s'est passé quelque chose, après quoi on va
 * demander l'état réel. Sans cela, il suffirait de connaître l'URL de rappel
 * pour se faire livrer gratuitement.
 */

/** Contexte d'appel, exigé par Nita pour la traçabilité. */
export interface ContexteAppel {
  adresseIp: string;
  lat?: string | undefined;
  lng?: string | undefined;
}

interface CommandeAPayer {
  id: string;
  total: number;
  merchant_id: string | null;
  type: string;
}

/**
 * Ouvre le paiement d'une commande et renvoie le code à régler.
 *
 * Le code retourné est celui que le client présentera au guichet Nita ou
 * saisira dans MYNITA. Tant qu'il n'est pas réglé, la commande reste
 * invisible pour le boutiquier (voir la migration 0017).
 */
export async function ouvrirPaiement(
  orderId: string,
  contexte: ContexteAppel,
): Promise<{ codeAchat: string; montant: number }> {
  const db = serviceClient();

  // Le montant vient de la base, jamais de la requête : c'est le même
  // principe que pour la commande elle-même.
  const { data: commande, error } = await db
    .from('orders')
    .select('id, total, merchant_id, type, user_id')
    .eq('id', orderId)
    .single();
  if (error) throw error;

  const { id, total, type } = commande as CommandeAPayer & { user_id: string };

  const { data: profil } = await db
    .from('profiles')
    .select('phone')
    .eq('id', (commande as { user_id: string }).user_id)
    .single();

  const telephone = (profil as { phone: string | null } | null)?.phone;
  if (!telephone) {
    throw new NitaError('Aucun numéro sur le compte : paiement mobile impossible', 400, false);
  }

  const libelle = type === 'courier' ? 'Course Tovo' : 'Commande Tovo';

  const achat = await creerAchat({
    // L'identifiant de la commande fait l'identifiant de la demande : Nita
    // l'exige unique, et il nous permet de retrouver la commande depuis un
    // statut sans table de correspondance.
    requestId: id,
    montant: total,
    description: [libelle],
    motif: libelle,
    phoneClient: versTelephoneNita(telephone),
    adresseIp: contexte.adresseIp,
    ...(env.NITA_WEBHOOK_SECRET && env.PUBLIC_BASE_URL
      ? { urlCallback: `${env.PUBLIC_BASE_URL}/webhooks/nita/${env.NITA_WEBHOOK_SECRET}` }
      : {}),
    lat: contexte.lat,
    lng: contexte.lng,
  });

  const { error: erreurRef } = await db
    .from('orders')
    .update({ payment_ref: achat.codeAchat })
    .eq('id', id);
  if (erreurRef) throw erreurRef;

  return achat;
}

/**
 * Va demander à Nita où en est le paiement, et en tire les conséquences.
 *
 * Appelée par le callback de Nita comme par la vérification périodique. Les
 * deux peuvent tomber en même temps sur la même commande : `mark_order_paid`
 * est idempotente et ne renvoie vrai qu'au passage effectif, ce qui évite de
 * prévenir deux fois le boutiquier.
 *
 * @returns l'état constaté, ou null si Nita n'a pas su répondre.
 */
export async function verifierPaiement(
  orderId: string,
  contexte: ContexteAppel,
): Promise<'paid' | 'pending' | 'failed' | null> {
  const db = serviceClient();

  const retour = await statutAchat(orderId, contexte);

  if (retour.code === STATUT_ACHAT.paye) {
    const { data: aChange, error } = await db.rpc('mark_order_paid', {
      p_order_id: orderId,
      p_reference: retour.codeAchat,
    });
    if (error) throw error;

    // Seulement au premier passage : le boutiquier ne doit pas recevoir deux
    // fois la même commande parce que Nita a rappelé deux fois.
    if (aChange === true) {
      await notifierBoutique(orderId);
    }
    return 'paid';
  }

  if (retour.code === STATUT_ACHAT.annule || retour.code === STATUT_ACHAT.bloque) {
    const { error } = await db.rpc('mark_order_payment_failed', { p_order_id: orderId });
    if (error) throw error;
    return 'failed';
  }

  if (retour.code === STATUT_ACHAT.nonPaye) return 'pending';

  return null;
}

/**
 * Annule l'achat Nita d'une commande abandonnée.
 *
 * Sans cela, le code resterait payable : le client réglerait au guichet une
 * commande que plus personne n'attend.
 */
export async function fermerPaiement(orderId: string, contexte: ContexteAppel): Promise<void> {
  const db = serviceClient();
  const { data } = await db
    .from('orders')
    .select('payment_ref, payment_status')
    .eq('id', orderId)
    .single();

  const commande = data as { payment_ref: string | null; payment_status: string } | null;
  if (!commande?.payment_ref || commande.payment_status !== 'pending') return;

  await annulerAchat(commande.payment_ref, orderId, contexte);
  await db.rpc('mark_order_payment_failed', { p_order_id: orderId });
}

/**
 * Repasse sur les paiements en attente.
 *
 * Le callback de Nita peut ne jamais arriver : serveur redéployé, réseau
 * coupé, ou simple oubli côté Nita. Un client qui a payé au guichet
 * resterait alors sans commande, et le boutiquier n'en saurait rien.
 */
export async function verifierPaiementsEnAttente(
  contexte: ContexteAppel,
): Promise<{ examinees: number; payees: number; echouees: number }> {
  const db = serviceClient();
  const { data, error } = await db.rpc('orders_awaiting_payment', {
    p_age_max_min: 720,
    p_limite: 50,
  });
  if (error) throw error;

  const commandes = (data ?? []) as { id: string; payment_ref: string | null }[];
  let payees = 0;
  let echouees = 0;

  for (const commande of commandes) {
    // Sans code d'achat, il n'y a rien à interroger : la création chez Nita
    // avait échoué, le client n'a jamais reçu de code à payer.
    if (!commande.payment_ref) continue;

    try {
      const etat = await verifierPaiement(commande.id, contexte);
      if (etat === 'paid') payees++;
      if (etat === 'failed') echouees++;
    } catch {
      // Une commande qui échoue ne doit pas arrêter les autres : elle sera
      // reprise au prochain passage.
    }
  }

  return { examinees: commandes.length, payees, echouees };
}
