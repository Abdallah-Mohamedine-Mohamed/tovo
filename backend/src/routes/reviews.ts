import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';

/**
 * Avis sur une commande livrée.
 *
 * La note d'une boutique décide de son chiffre d'affaires : c'est le premier
 * chiffre que regarde un client. Les garanties sont donc en base — le trigger
 * `guard_review` exige une commande livrée et vraiment passée par l'auteur,
 * et fixe lui-même la boutique et le livreur notés d'après la commande.
 *
 * Sans cela, il suffisait d'une commande pour noter toute la plateforme, et
 * rien dans les notes affichées n'aurait permis de s'en apercevoir.
 */

const reviewSchema = z.object({
  rating: z.number().int().min(1).max(5),
  comment: z.string().max(1000).nullable().default(null),
});

export async function reviewRoutes(app: FastifyInstance): Promise<void> {
  app.post('/orders/:orderId/review', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ orderId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const body = reviewSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    // `upsert` sur (order_id, user_id) : un client qui corrige sa note ne doit
    // pas se heurter à une erreur de doublon. `merchant_id` et `driver_id`
    // sont volontairement absents — le trigger les impose d'après la commande.
    const { error } = await request.supabase!.from('reviews').upsert(
      {
        order_id: params.data.orderId,
        user_id: request.user!.id,
        rating: body.data.rating,
        comment: body.data.comment,
      },
      { onConflict: 'order_id,user_id' },
    );

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.code(201).send(envelope('Merci, votre avis est enregistré.', []));
  });

  /**
   * Les avis d'une boutique, pour sa fiche.
   *
   * Lecture publique assumée : un avis sert à décider avant de commander.
   * Le nom de l'auteur est joint, jamais son téléphone.
   */
  app.get('/merchants/:merchantId/reviews', async (request, reply) => {
    const params = z.object({ merchantId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const query = z
      .object({ limit: z.coerce.number().int().min(1).max(50).default(20) })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    const { data, error } = await request.supabase!
      .from('reviews')
      .select('id, rating, comment, created_at, profiles(full_name)')
      .eq('merchant_id', params.data.merchantId)
      .order('created_at', { ascending: false })
      .limit(query.data.limit);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const avis = (data ?? []).map((r) => {
      const ligne = r as Record<string, unknown>;
      const auteur = ligne['profiles'] as { full_name?: string } | null;
      return {
        id: ligne['id'],
        rating: ligne['rating'],
        comment: ligne['comment'],
        created_at: ligne['created_at'],
        author: auteur?.full_name ?? 'Client Tovo',
      };
    });

    return reply.send({ reviews: avis });
  });
}
