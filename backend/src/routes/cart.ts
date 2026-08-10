import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { cartSummary, envelope, quickReplies } from '../components/builders.js';

/**
 * Panier — sans tour LLM.
 *
 * C'est l'action la plus fréquente de l'app. La faire transiter par le
 * modèle coûterait une seconde et quelques centimes à chaque tap, pour un
 * calcul entièrement déterministe. Les routes appellent directement les
 * fonctions Postgres, qui font autorité sur les prix.
 *
 * Chaque réponse renvoie l'enveloppe du contrat (content + components), pour
 * que le fil de conversation reste homogène : côté Flutter, un panier mis à
 * jour par un tap et un panier renvoyé par l'IA sont le même composant.
 */

const selectionsSchema = z.array(
  z.object({
    option_id: z.string().uuid(),
    value_ids: z.array(z.string().uuid()),
  }),
);

const addItemSchema = z.object({
  product_id: z.string().uuid(),
  quantity: z.number().int().positive().max(50).default(1),
  selections: selectionsSchema.default([]),
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
});

const quantitySchema = z.object({
  quantity: z.number().int().min(0).max(50),
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
});

const positionSchema = z.object({
  lat: z.coerce.number().min(-90).max(90).optional(),
  lng: z.coerce.number().min(-180).max(180).optional(),
});

export async function cartRoutes(app: FastifyInstance): Promise<void> {
  /** Charge le panier et le renvoie dans l'enveloppe du contrat. */
  async function renvoyerPanier(
    db: NonNullable<import('fastify').FastifyRequest['supabase']>,
    lat: number | undefined,
    lng: number | undefined,
    content: string,
  ) {
    const { data, error } = await db.rpc('cart_view', {
      p_lat: lat ?? null,
      p_lng: lng ?? null,
    });
    if (error) return { failure: toHttpFailure(error) };

    const payload = (data ?? {}) as Record<string, unknown>;
    const vide = !payload.cart_id || (payload.items as unknown[])?.length === 0;

    return {
      envelope: envelope(
        vide ? 'Votre panier est vide.' : content,
        vide ? [] : [cartSummary(payload)],
      ),
    };
  }

  app.get('/cart', { preHandler: app.requireAuth }, async (request, reply) => {
    const query = positionSchema.safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'position invalide' });

    const result = await renvoyerPanier(
      request.supabase!,
      query.data.lat,
      query.data.lng,
      'Voici votre panier.',
    );
    if (result.failure) return reply.code(result.failure.status).send(result.failure.body);
    return reply.send(result.envelope);
  });

  app.post('/cart/items', { preHandler: app.requireAuth }, async (request, reply) => {
    const body = addItemSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const { error } = await request.supabase!.rpc('cart_add_item', {
      p_product_id: body.data.product_id,
      p_quantity: body.data.quantity,
      p_selections: body.data.selections,
    });

    if (error) {
      const failure = toHttpFailure(error);
      // Panier déjà ouvert ailleurs : on ne vide rien de force, on rend la
      // main à l'utilisateur avec un choix explicite.
      if (error.code === 'P0003') {
        return reply.code(409).send({
          ...envelope(failure.body.error, [
            quickReplies([
              { label: 'Vider et recommencer', value: 'vider_panier' },
              { label: 'Garder mon panier', value: 'garder_panier' },
            ]),
          ]),
          // `error` EN PLUS de `content`, et ce n'est pas une redondance.
          //
          // Sur un statut ≥ 400 l'application lit `error` ; une enveloppe
          // n'a que `content`. Elle affichait donc les deux boutons — qui
          // venaient bien des composants — au-dessus d'un « Une erreur est
          // survenue » générique, alors que le serveur avait rédigé « votre
          // panier contient déjà des articles de telle boutique ».
          //
          // Le client sait ce qu'on lui demande de trancher sans avoir à
          // deviner, et les versions déjà installées en profitent sans
          // réinstallation.
          error: failure.body.error,
        });
      }
      return reply.code(failure.status).send(failure.body);
    }

    const result = await renvoyerPanier(
      request.supabase!,
      body.data.lat,
      body.data.lng,
      'Ajouté à votre panier.',
    );
    if (result.failure) return reply.code(result.failure.status).send(result.failure.body);
    return reply.send(result.envelope);
  });

  app.patch('/cart/items/:itemId', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ itemId: z.string().uuid() }).safeParse(request.params);
    const body = quantitySchema.safeParse(request.body);
    if (!params.success || !body.success) {
      return reply.code(400).send({ error: 'requête invalide' });
    }

    const { error } = await request.supabase!.rpc('cart_set_quantity', {
      p_item_id: params.data.itemId,
      p_quantity: body.data.quantity,
    });
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const result = await renvoyerPanier(
      request.supabase!,
      body.data.lat,
      body.data.lng,
      'Panier mis à jour.',
    );
    if (result.failure) return reply.code(result.failure.status).send(result.failure.body);
    return reply.send(result.envelope);
  });

  app.delete('/cart/items/:itemId', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ itemId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { error } = await request.supabase!.rpc('cart_set_quantity', {
      p_item_id: params.data.itemId,
      p_quantity: 0,
    });
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const result = await renvoyerPanier(
      request.supabase!,
      undefined,
      undefined,
      'Article retiré.',
    );
    if (result.failure) return reply.code(result.failure.status).send(result.failure.body);
    return reply.send(result.envelope);
  });

  /** Vider le panier — la suite du choix proposé en cas de conflit de boutique. */
  app.delete('/cart', { preHandler: app.requireAuth }, async (request, reply) => {
    const { error } = await request.supabase!.from('carts').delete().eq('user_id', request.user!.id);
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send(envelope('Panier vidé.'));
  });
}
