import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';
import { embed, embeddingsEnabled } from '../services/embeddings.js';

/**
 * Relevés de prix de la concurrence.
 *
 * Le comparateur de Tovo est hybride : les partenaires sont commandables,
 * les offres externes seulement consultables — `is_orderable = false` dans
 * `compare_prices`, ce qui fait afficher « Voir » et non « Commander ».
 *
 * Ces offres sont saisies à la main depuis l'admin. Moissonner Jumia ou les
 * boutiques locales serait fragile et juridiquement discutable ; à Niamey,
 * l'essentiel des prix concurrents se relève de toute façon en magasin.
 *
 * Le point qui décide de tout : `compare_prices` exige `embedding is not
 * null`. Une offre enregistrée sans vecteur n'apparaît JAMAIS, sans qu'aucune
 * erreur ne le signale. On calcule donc l'embedding à l'écriture, et on
 * refuse plutôt que d'enregistrer une offre invisible.
 */

const offreSchema = z.object({
  source: z.string().min(1).max(60),
  title: z.string().min(1).max(200),
  price: z.number().int().min(0),
  source_url: z.string().url().nullable().default(null),
  image_url: z.string().url().nullable().default(null),
  in_stock: z.boolean().default(true),
  /** Jours de validité. Un prix relevé en boutique tient rarement plus. */
  valid_days: z.number().int().min(1).max(365).default(30),
});

/** Le texte qui porte le sens de l'offre, pour la recherche vectorielle. */
function texteIndexable(offre: { title: string; source: string }): string {
  return `${offre.title} — ${offre.source}`;
}

export async function externalOfferRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Réservé à l'admin : ces prix s'affichent à tous les clients.
   *
   * Enchaîné après `requireAuth`, qui a déjà rempli `request.user`.
   */
  const exigerAdmin = async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.user?.role !== 'admin') {
      return reply.code(403).send({ error: 'réservé à l’administration' });
    }
  };

  const admin = { preHandler: [app.requireAuth, exigerAdmin] };

  app.get('/admin/external-offers', admin, async (request, reply) => {

    const { data, error } = await request.supabase!
      .from('external_offers')
      .select('id, source, source_url, title, image_url, price, in_stock, expires_at, embedded_at')
      .order('fetched_at', { ascending: false })
      .limit(200);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send({ offers: data ?? [] });
  });

  app.post('/admin/external-offers', admin, async (request, reply) => {

    const body = offreSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    if (!embeddingsEnabled) {
      return reply.code(503).send({
        error: 'indexation indisponible',
        message:
          'Sans clé Gemini, l’offre serait enregistrée mais n’apparaîtrait dans aucune comparaison.',
      });
    }

    let vecteur: number[];
    try {
      vecteur = await embed(texteIndexable(body.data), 'document');
    } catch (cause) {
      request.log.error({ cause }, 'embedding de l’offre externe impossible');
      return reply.code(502).send({
        error: 'indexation impossible',
        message: 'Réessayez : sans indexation, l’offre resterait invisible aux clients.',
      });
    }

    const expiration = new Date(Date.now() + body.data.valid_days * 86_400_000).toISOString();

    const { data, error } = await request.supabase!
      .from('external_offers')
      .insert({
        source: body.data.source,
        title: body.data.title,
        price: body.data.price,
        source_url: body.data.source_url,
        image_url: body.data.image_url,
        in_stock: body.data.in_stock,
        embedding: vecteur,
        embedded_at: new Date().toISOString(),
        expires_at: expiration,
        created_by: request.user!.id,
      })
      .select('id')
      .single();

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply
      .code(201)
      .send({ ...envelope('Offre enregistrée.', []), offer_id: (data as { id: string }).id });
  });

  app.patch(
    '/admin/external-offers/:offerId',
    admin,
    async (request, reply) => {

      const params = z.object({ offerId: z.string().uuid() }).safeParse(request.params);
      if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

      const body = offreSchema.partial().safeParse(request.body);
      if (!body.success) {
        return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
      }

      const modif: Record<string, unknown> = {};
      for (const champ of ['source', 'title', 'price', 'source_url', 'image_url', 'in_stock'] as const) {
        if (body.data[champ] !== undefined) modif[champ] = body.data[champ];
      }
      if (body.data.valid_days !== undefined) {
        modif['expires_at'] = new Date(
          Date.now() + body.data.valid_days * 86_400_000,
        ).toISOString();
      }

      // Le titre ou la source changent : l'embedding porte sur eux, il
      // devient faux. Le laisser en place ferait remonter l'offre sur
      // l'ancien libellé — une erreur qui ne se voit jamais.
      if (body.data.title !== undefined || body.data.source !== undefined) {
        const { data: actuelle } = await request.supabase!
          .from('external_offers')
          .select('title, source')
          .eq('id', params.data.offerId)
          .single();

        const ligne = actuelle as { title: string; source: string } | null;
        if (ligne) {
          try {
            modif['embedding'] = await embed(
              texteIndexable({
                title: body.data.title ?? ligne.title,
                source: body.data.source ?? ligne.source,
              }),
              'document',
            );
            modif['embedded_at'] = new Date().toISOString();
          } catch (cause) {
            request.log.error({ cause }, 'réindexation de l’offre impossible');
            return reply.code(502).send({ error: 'réindexation impossible' });
          }
        }
      }

      const { error } = await request.supabase!
        .from('external_offers')
        .update(modif)
        .eq('id', params.data.offerId);

      if (error) {
        const failure = toHttpFailure(error);
        return reply.code(failure.status).send(failure.body);
      }
      return reply.send(envelope('Offre mise à jour.', []));
    },
  );

  app.delete(
    '/admin/external-offers/:offerId',
    admin,
    async (request, reply) => {

      const params = z.object({ offerId: z.string().uuid() }).safeParse(request.params);
      if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

      const { error } = await request.supabase!
        .from('external_offers')
        .delete()
        .eq('id', params.data.offerId);

      if (error) {
        const failure = toHttpFailure(error);
        return reply.code(failure.status).send(failure.body);
      }
      return reply.send(envelope('Offre supprimée.', []));
    },
  );
}
