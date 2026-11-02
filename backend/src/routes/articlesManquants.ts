import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { deciderManquant, RefusManquant, signalerManquants } from '../services/articlesManquants.js';

/**
 * Un article manque (02/11) : la boutique le signale, le client choisit.
 * Les règles et les vérifications sont dans services/articlesManquants.ts.
 */
export async function articlesManquantsRoutes(app: FastifyInstance): Promise<void> {
  app.post('/merchant/orders/:orderId/manquants', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid() }).safeParse(request.params);
    const body = z.object({ order_item_ids: z.array(z.string().uuid()).min(1).max(50) }).safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: 'requête invalide' });
    try {
      const signales = await signalerManquants(request.user!.id, params.data.orderId, body.data.order_item_ids);
      return reply.send({ signales });
    } catch (error) {
      if (error instanceof RefusManquant) return reply.code(error.status).send({ error: error.message });
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
  });

  app.post('/orders/:orderId/manquants/:manquantId', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid(), manquantId: z.string().uuid() }).safeParse(request.params);
    const body = z.object({
      decision: z.enum(['remplacer', 'retirer', 'annuler']),
      product_id: z.string().uuid().optional(),
    }).safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: 'requête invalide' });
    try {
      const resultat = await deciderManquant(
        { clientId: request.user!.id }, params.data.orderId, params.data.manquantId,
        body.data.decision, body.data.product_id,
      );
      return reply.send(resultat);
    } catch (error) {
      if (error instanceof RefusManquant) return reply.code(error.status).send({ error: error.message });
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
  });
}
