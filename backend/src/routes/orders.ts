import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope, orderTracking } from '../components/builders.js';
import { notifierBoutique } from '../services/orderNotifications.js';
import { ouvrirPaiement } from '../services/payments.js';
import { paiementMobileActif } from '../config/env.js';

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

const courierSchema = z.object({
  type: z.literal('courier'),
  client_order_id: z.string().uuid(),
  pickup_hint: z.string().min(1).max(300),
  pickup: positionSchema,
  dropoff_hint: z.string().min(1).max(300),
  dropoff: positionSchema,
  parcel: z.enum(['small', 'medium', 'large']).default('small'),
  payment_method: z.enum(['cash', 'mobile_money']).default('cash'),
  scheduled_for: z.string().datetime().nullable().default(null),
  parcel_note: z.string().max(300).nullable().default(null),
});

const createOrderSchema = z.discriminatedUnion('type', [deliverySchema, courierSchema]);

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
            p_dropoff_lat: body.data.dropoff.lat,
            p_dropoff_lng: body.data.dropoff.lng,
            p_parcel: body.data.parcel,
            p_payment: body.data.payment_method,
            p_scheduled_for: body.data.scheduled_for,
            p_parcel_note: body.data.parcel_note,
          });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    // La notification la plus critique du système : tant que le boutiquier
    // ne l'a pas vue, rien n'avance et le client attend. Elle part quel que
    // soit le mode de paiement — le règlement ne doit rien retenir.
    if (body.data.type === 'delivery') {
      notifierBoutique(orderId as string).catch((cause) => {
        request.log.error({ cause, orderId }, 'notification boutique impossible');
      });
    }

    // Paiement mobile : on ouvre un achat chez Nita pour que le client puisse
    // régler d'avance, et pour que le système puisse constater ce règlement
    // tout seul. Un échec ici n'empêche rien : le client peut toujours
    // envoyer l'argent directement par Nita, et le livreur le constatera à la
    // livraison. Retenir la commande pour ça la ferait arriver froide.
    let codeAchat: string | null = null;
    if (body.data.payment_method === 'mobile_money' && paiementMobileActif) {
      try {
        const achat = await ouvrirPaiement(orderId as string, {
          adresseIp: request.ip,
          lat: String(body.data.dropoff.lat),
          lng: String(body.data.dropoff.lng),
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
    const message = codeAchat
      ? `Commande enregistrée, la boutique la prépare. Vous pouvez régler dès maintenant ` +
        `avec le code ${codeAchat} depuis MYNITA, ou payer à la livraison.`
      : 'Commande enregistrée. Je vous tiens au courant.';

    return reply
      .code(201)
      .send(
        envelope(message, [
          orderTracking({
            ...(suivi.data as Record<string, unknown>),
            ...(codeAchat ? { payment_code: codeAchat } : {}),
          }),
        ]),
      );
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

  app.get('/orders', { preHandler: app.requireAuth }, async (request, reply) => {
    const query = z
      .object({ limit: z.coerce.number().int().min(1).max(50).default(20) })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    const { data, error } = await request.supabase!
      .from('orders')
      .select('id, type, status, total, placed_at, delivered_at, merchant_id')
      .order('placed_at', { ascending: false })
      .limit(query.data.limit);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send({ orders: data ?? [] });
  });
}
