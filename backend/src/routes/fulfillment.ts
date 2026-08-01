import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope, orderTracking } from '../components/builders.js';
import { queueDispatch } from '../services/dispatch.js';

/**
 * Exécution d'une commande — boutiquier et livreur.
 *
 * Ces routes ne décident rien : elles appellent `advance_order_status()`,
 * qui détient les transitions autorisées. Un boutiquier qui tenterait de
 * marquer une commande « livrée » se fait refuser par la base, pas par un
 * `if` de ce fichier.
 *
 * Le dispatch se déclenche au passage à `ready` — le seul moment où une
 * commande devient prenable par un livreur.
 */

const statusSchema = z.object({
  status: z.enum([
    'confirmed',
    'preparing',
    'ready',
    'picked_up',
    'delivering',
    'delivered',
    'cancelled',
  ]),
  note: z.string().max(300).nullable().default(null),
});

const positionSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  order_id: z.string().uuid().nullable().default(null),
  heading: z.number().nullable().default(null),
  speed_kmh: z.number().nullable().default(null),
});

export async function fulfillmentRoutes(app: FastifyInstance): Promise<void> {
  app.post('/orders/:orderId/status', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid() }).safeParse(request.params);
    const body = statusSchema.safeParse(request.body);
    if (!params.success || !body.success) {
      return reply.code(400).send({ error: 'requête invalide' });
    }

    const db = request.supabase!;
    const { error } = await db.rpc('advance_order_status', {
      p_order_id: params.data.orderId,
      p_status: body.data.status,
      p_note: body.data.note,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    // « Prête » est le seul statut qui ouvre la course aux livreurs.
    if (body.data.status === 'ready') {
      // La mise en file ne doit jamais faire échouer le changement de
      // statut : la commande est prête, c'est un fait acquis même si la
      // notification part mal.
      queueDispatch(params.data.orderId).catch((cause) => {
        request.log.error({ cause, orderId: params.data.orderId }, 'mise en file du dispatch impossible');
      });
    }

    const suivi = await db.rpc('order_tracking', { p_order_id: params.data.orderId });
    if (suivi.error || !suivi.data) {
      return reply.send(envelope('Statut mis à jour.'));
    }

    return reply.send(
      envelope('Statut mis à jour.', [
        orderTracking(suivi.data as Record<string, unknown>),
      ]),
    );
  });

  /**
   * Pool des courses disponibles. La RLS fait le filtrage : un livreur ne
   * voit que les commandes `ready` sans livreur, dans sa zone.
   */
  app.get('/driver/pool', { preHandler: app.requireAuth }, async (request, reply) => {
    const { data, error } = await request.supabase!
      .from('orders')
      .select('id, type, total, dropoff_hint, placed_at, driver_earning, merchant_id')
      .is('driver_id', null)
      .eq('status', 'ready')
      .order('placed_at', { ascending: true })
      .limit(20);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send({ orders: data ?? [] });
  });

  /**
   * Acceptation d'une course.
   *
   * `accept_order()` est atomique : sur deux livreurs qui acceptent en même
   * temps, un seul obtient `true`. Le second reçoit un 409 explicite plutôt
   * qu'une erreur générique — sur le terrain, savoir que la course vient
   * d'être prise vaut mieux que « une erreur est survenue ».
   */
  app.post('/orders/:orderId/accept', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const db = request.supabase!;
    const { data, error } = await db.rpc('accept_order', { target_order: params.data.orderId });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    if (data !== true) {
      return reply.code(409).send({ error: 'course déjà prise', code: 'ALREADY_TAKEN' });
    }

    const suivi = await db.rpc('order_tracking', { p_order_id: params.data.orderId });
    return reply.send(
      envelope('Course acceptée.', [
        ...(suivi.data ? [orderTracking(suivi.data as Record<string, unknown>)] : []),
      ]),
    );
  });

  /**
   * Ping de position.
   *
   * Une seule requête écrit le ping et rafraîchit le profil. Deux appels
   * séparés toutes les dix secondes doubleraient les allers-retours sur un
   * réseau déjà fragile.
   */
  app.post('/driver/location', { preHandler: app.requireAuth }, async (request, reply) => {
    const body = positionSchema.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: 'position invalide' });

    const { error } = await request.supabase!.rpc('push_driver_location', {
      p_lat: body.data.lat,
      p_lng: body.data.lng,
      p_order_id: body.data.order_id,
      p_heading: body.data.heading,
      p_speed: body.data.speed_kmh,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    // Réponse volontairement vide : ce point est appelé toutes les dix
    // secondes, chaque octet renvoyé est du forfait data consommé.
    return reply.code(204).send();
  });

  /** Solde et gains de la journée, pour l'écran d'accueil du livreur. */
  app.get('/driver/summary', { preHandler: app.requireAuth }, async (request, reply) => {
    const { data, error } = await request.supabase!.rpc('driver_daily_summary');
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    const ligne = Array.isArray(data) ? data[0] : data;
    return reply.send(ligne ?? { courses: 0, earned: 0, cash_collected: 0, cash_due: 0 });
  });

  /** Commandes entrantes d'une boutique, pour le tableau du boutiquier. */
  app.get('/merchant/orders', { preHandler: app.requireAuth }, async (request, reply) => {
    const query = z
      .object({
        status: z
          .enum(['pending', 'confirmed', 'preparing', 'ready', 'assigned', 'delivering'])
          .optional(),
      })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    let builder = request.supabase!
      .from('orders')
      .select('id, status, total, items_total, merchant_payout, placed_at, dropoff_hint')
      .order('placed_at', { ascending: false })
      .limit(50);

    if (query.data.status) builder = builder.eq('status', query.data.status);

    const { data, error } = await builder;
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send({ orders: data ?? [] });
  });
}
