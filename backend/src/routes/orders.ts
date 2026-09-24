import type { SupabaseClient } from '@supabase/supabase-js';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope, orderTracking } from '../components/builders.js';
import {
  notifierBoutique,
  notifierLivreursCommandeRecue,
} from '../services/orderNotifications.js';
import { queueDispatch } from '../services/dispatch.js';
import { ouvrirPaiement } from '../services/payments.js';
import { paiementMobileActif } from '../config/env.js';
import { messageLivreurEnRoute } from '../services/livreur.js';

/**
 * Commandes — sans tour LLM, et c'est délibéré.
 *
 * Passer commande engage de l'argent. L'action exige un geste explicite de
 * l'utilisateur sur un cart_summary ou un courier_form ; aucun outil du
 * modèle ne peut la déclencher.
 *
 * L'idempotence repose sur client_order_id, généré par Flutter AVANT
 * l'envoi. Rejouer la même requête après une coupure renvoie la commande
 * déjà créée. Sur le réseau nigérien, ce n'est pas une précaution
 * théorique : c'est la différence entre une commande et deux.
 */

const positionSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
});

const deliverySchema = z.object({
  type: z.literal('delivery'),
  client_order_id: z.string().uuid(),
  dropoff_hint: z.string().min(1).max(300),
  dropoff: positionSchema,
  payment_method: z.enum(['cash', 'mobile_money']).default('cash'),
  note: z.string().max(500).nullable().default(null),
});

/** Un champ texte facultatif : vide ou blanc vaut absent. */
const facultatif = (max: number) =>
  z.preprocess(
    (v) => (typeof v === 'string' && v.trim() === '' ? null : v),
    z.string().max(max).nullable().default(null),
  );

/**
 * Un livreur, pas un formulaire.
 *
 * Seule la prise en charge est requise : c'est là que le livreur se rend, et
 * il appelle le client pour le reste. Destination, destinataire et taille
 * sont facultatifs — au Niger, le téléphone fait le travail que l'adresse
 * fait ailleurs. Sans destination, le prix est le tarif ville fixe
 * (platform_settings.courier_city_flat).
 */
const courierSchema = z.object({
  type: z.literal('courier'),
  client_order_id: z.string().uuid(),
  pickup_hint: facultatif(300),
  pickup: positionSchema,
  dropoff_hint: facultatif(300),
  dropoff: positionSchema.nullable().default(null),
  parcel: z.enum(['small', 'medium', 'large']).default('small'),
  payment_method: z.enum(['cash', 'mobile_money']).default('cash'),
  scheduled_for: z.string().datetime().nullable().default(null),
  parcel_note: facultatif(300),
  /** Qui appeler à l'arrivée ; à défaut, le livreur appelle le client. */
  dropoff_contact: facultatif(30),
  /** Chez qui le prendre, si ce n'est pas l'expéditeur lui-même. */
  pickup_contact: facultatif(30),
  /**
   * « deposer » : le livreur vient chez le client (départ = sa position).
   * « recuperer » : il va chercher ailleurs et apporte au client (arrivée =
   * sa position, départ décrit par pickup_hint). Migration 0059.
   */
  mode: z.enum(['deposer', 'recuperer']).default('deposer'),
});

/**
 * La conversation d'où part la commande. Facultative : le panier ouvert
 * depuis le catalogue n'en a pas toujours une.
 */
const avecConversation = { conversation_id: z.string().uuid().nullable().default(null) };

const createOrderSchema = z.discriminatedUnion('type', [
  deliverySchema.extend(avecConversation),
  courierSchema.extend(avecConversation),
]);

/**
 * Inscrit la commande dans la conversation d'où elle part.
 *
 * Sans ça, une commande passée par un bouton n'existait que sur l'écran :
 * en rouvrant la conversation, le suivi avait disparu et la carte
 * « Appeler un livreur » était de nouveau là, active, comme si rien
 * n'avait été commandé. On écrit donc le geste et le suivi, et on éteint
 * la carte livreur qui a servi.
 *
 * client_message_id = client_order_id : l'index unique
 * (conversation_id, client_message_id) fait qu'une requête rejouée après
 * une coupure n'inscrit pas deux fois la même commande.
 */
async function inscrireDansLaConversation(
  db: SupabaseClient,
  conversationId: string,
  clientOrderId: string,
  geste: string,
  reponse: { content: string; components: unknown[] },
  eteindre: string | null,
): Promise<void> {
  const { error } = await db.from('messages').insert({
    conversation_id: conversationId,
    role: 'user',
    content: geste,
    client_message_id: clientOrderId,
  });
  // Déjà inscrite (requête rejouée), ou conversation d'un autre (RLS).
  if (error) return;
  await db.from('messages').insert({
    conversation_id: conversationId,
    role: 'assistant',
    content: reponse.content,
    components: reponse.components,
  });

  if (!eteindre) return;
  const { data } = await db
    .from('messages')
    .select('id, components')
    .eq('conversation_id', conversationId)
    .eq('role', 'assistant')
    .order('created_at', { ascending: false })
    .limit(10);
  for (const m of (data ?? []) as { id: string; components: unknown }[]) {
    const composants = Array.isArray(m.components) ? m.components : [];
    const index = composants.findIndex(
      (c) => (c as { type?: string })?.type === eteindre && !(c as { data?: { utilise?: boolean } }).data?.utilise,
    );
    if (index < 0) continue;
    const c = composants[index] as { data?: Record<string, unknown> };
    const modifies = [...composants];
    modifies[index] = { ...c, data: { ...(c.data ?? {}), utilise: true } };
    await db.from('messages').update({ components: modifies }).eq('id', m.id);
    return;
  }
}

export async function orderRoutes(app: FastifyInstance): Promise<void> {
  app.post('/orders', { preHandler: app.requireAuth }, async (request, reply) => {
    const body = createOrderSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const db = request.supabase!;

    // Aucun montant n'est accepté du client : les fonctions ci-dessous ne
    // prennent pas de total en paramètre, elles le calculent.
    const { data: orderId, error } =
      body.data.type === 'delivery'
        ? await db.rpc('place_delivery_order', {
            p_client_order_id: body.data.client_order_id,
            p_dropoff_hint: body.data.dropoff_hint,
            p_lat: body.data.dropoff.lat,
            p_lng: body.data.dropoff.lng,
            p_payment: body.data.payment_method,
            p_note: body.data.note,
          })
        : await db.rpc('place_courier_order', {
            p_client_order_id: body.data.client_order_id,
            p_pickup_hint: body.data.pickup_hint,
            p_pickup_lat: body.data.pickup.lat,
            p_pickup_lng: body.data.pickup.lng,
            p_dropoff_hint: body.data.dropoff_hint,
            p_dropoff_lat: body.data.dropoff?.lat ?? null,
            p_dropoff_lng: body.data.dropoff?.lng ?? null,
            p_parcel: body.data.parcel,
            p_payment: body.data.payment_method,
            p_scheduled_for: body.data.scheduled_for,
            p_parcel_note: body.data.parcel_note,
            p_dropoff_contact: body.data.dropoff_contact,
            p_pickup_contact: body.data.pickup_contact,
            // Seulement pour « récupérer » : sans la migration 0059, la base
            // ne connaît pas ce paramètre, et « déposer » doit continuer de
            // fonctionner.
            ...(body.data.mode === 'recuperer' ? { p_mode: 'recuperer' } : {}),
          });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    if (body.data.type === 'delivery') {
      notifierBoutique(orderId as string).catch((cause) => {
        request.log.error({ cause, orderId }, 'notification boutique impossible');
      });
      notifierLivreursCommandeRecue(orderId as string).catch((cause) => {
        request.log.error({ cause, orderId }, 'notification livreurs impossible');
      });
    } else if (!body.data.scheduled_for || new Date(body.data.scheduled_for) <= new Date()) {
      queueDispatch(orderId as string).catch((cause) => {
        request.log.error({ cause, orderId }, 'dispatch du colis impossible');
      });
    }

    // Paiement mobile : on ouvre un achat chez Nita pour que le client puisse
    // régler d'avance, et pour que le système puisse constater ce règlement
    // tout seul. Un échec ici n'empêche rien : le client peut toujours
    // envoyer l'argent directement par Nita, et le livreur le constatera à la
    // livraison. Retenir la commande pour ça la ferait arriver froide.
    let codeAchat: string | null = null;
    if (body.data.payment_method === 'mobile_money' && paiementMobileActif) {
      // Un colis sans destination : la position connue est celle du client.
      const point = (body.data.type === 'courier' ? body.data.dropoff : null)
        ?? (body.data.type === 'courier' ? body.data.pickup : body.data.dropoff);
      try {
        const achat = await ouvrirPaiement(orderId as string, {
          adresseIp: request.ip,
          lat: String(point.lat),
          lng: String(point.lng),
        });
        codeAchat = achat.codeAchat;
      } catch (cause) {
        // Le MESSAGE explicitement : `message` n'est pas énumérable sur une
        // Error, donc journaliser l'objet ne montre que son nom et son
        // statut. On y lisait « NitaError, statut 200 » sans jamais savoir
        // que Nita disait « nom ou mot de passe incorrect ».
        request.log.error(
          {
            orderId,
            erreur: cause instanceof Error ? cause.message : String(cause),
            statut: (cause as { statut?: number }).statut,
          },
          'ouverture du paiement Nita impossible',
        );
      }
    }

    const suivi = await db.rpc('order_tracking', { p_order_id: orderId });
    if (suivi.error) {
      const failure = toHttpFailure(suivi.error);
      return reply.code(failure.status).send(failure.body);
    }

    // La commande est déjà partie ; le code sert à régler d'avance plutôt
    // qu'à la débloquer. On le dit dans ces termes, sinon le client croit
    // devoir payer avant que la boutique ne commence.
    const message = body.data.type === 'courier'
      ? await messageLivreurEnRoute(db, codeAchat)
      : codeAchat
        ? `Commande enregistrée, la boutique la prépare. Vous pouvez régler dès maintenant ` +
          `avec le code ${codeAchat} depuis MYNITA, ou payer à la livraison.`
        : 'Commande enregistrée. Je vous tiens au courant.';

    const reponse = envelope(message, [
      orderTracking({
        ...(suivi.data as Record<string, unknown>),
        ...(codeAchat ? { payment_code: codeAchat } : {}),
      }),
    ]);

    if (body.data.conversation_id) {
      await inscrireDansLaConversation(
        db,
        body.data.conversation_id,
        body.data.client_order_id,
        body.data.type === 'courier' ? 'Appeler un livreur' : 'Commander',
        reponse,
        body.data.type === 'courier' ? 'courier_form' : null,
      ).catch((cause) => {
        // La commande est passée : ne pas l'inscrire n'est pas une raison
        // de la présenter comme ratée.
        request.log.error({ cause, orderId }, 'commande non inscrite dans la conversation');
      });
    }

    return reply.code(201).send(reponse);
  });

  app.get('/orders/:orderId', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { data, error } = await request.supabase!.rpc('order_tracking', {
      p_order_id: params.data.orderId,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    // La RLS renvoie null plutôt qu'une erreur quand la commande ne nous
    // regarde pas. On ne distingue pas « inexistante » de « pas à vous » :
    // la différence renseignerait un curieux sur ce qui existe.
    if (!data) return reply.code(404).send({ error: 'commande introuvable' });

    return reply.send(
      envelope('Voici le suivi de votre commande.', [
        orderTracking(data as Record<string, unknown>),
      ]),
    );
  });

  /**
   * Annuler — le bouton de la carte de suivi, sans passer par l'assistant.
   *
   * Indispensable depuis que « je veux un livreur » commande sans étape : un
   * vocal mal compris ne doit pas faire venir quelqu'un pour rien. La base
   * décide seule (cancel_my_order) : aucun livreur parti, rien d'encaissé.
   * Un refus est un motif à lire, pas une erreur : 200 et le motif en texte.
   */
  app.post('/orders/:orderId/cancel', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const db = request.supabase!;
    const { data: refus, error } = await db.rpc('cancel_my_order', {
      p_order_id: params.data.orderId,
      p_motif: null,
    });
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    // Pas de nouvelle carte de suivi : celle déjà affichée passe d'elle-même
    // à « annulée » (elle écoute la commande en temps réel). En renvoyer une
    // seconde empilait deux « Livraison annulée » l'une sous l'autre.
    return reply.send(envelope((refus as string | null) ?? 'C’est annulé. Aucun livreur ne viendra.'));
  });

  app.get('/orders', { preHandler: app.requireAuth }, async (request, reply) => {
    const query = z
      .object({ limit: z.coerce.number().int().min(1).max(50).default(20) })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    // La boutique et les articles en plus : l'accueil en tire sa carte
    // « Recommander », sans seconde requête. « 4 500 F » ne rappelle à
    // personne ce qu'il a mangé ; « 2 × Tacos poulet — Otakoss », si.
    const { data, error } = await request.supabase!
      .from('orders')
      .select('id, type, status, total, placed_at, delivered_at, merchant_id, merchants(name), order_items(product_name, quantity)')
      .order('placed_at', { ascending: false })
      .limit(query.data.limit);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    // Champs existants inchangés : les versions déjà installées ignorent
    // simplement `merchant_name` et `articles`.
    const orders = (data ?? []).map(({ merchants, order_items, ...commande }) => ({
      ...commande,
      merchant_name: (Array.isArray(merchants) ? merchants[0]?.name : (merchants as { name?: string } | null)?.name) ?? null,
      articles: ((order_items ?? []) as Array<{ product_name: string; quantity: number }>)
        .map((a) => ({ nom: a.product_name, quantite: a.quantity })),
    }));

    return reply.send({ orders });
  });
}
