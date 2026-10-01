import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { autourDe, rechercherLieux } from '../services/lieux.js';

/**
 * Les lieux de Niamey (OpenStreetMap), pour l'écran « Choisir où livrer » :
 * chercher un quartier ou un repère par son nom, et nommer l'endroit où
 * l'épingle est posée. Gratuit : nos données, en mémoire, sans Google.
 */
export async function lieuRoutes(app: FastifyInstance): Promise<void> {
  app.get('/lieux/recherche', { preHandler: app.requireAuth }, async (request, reply) => {
    const query = z.object({ q: z.string().max(80).default('') }).safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });
    return reply.send({ lieux: rechercherLieux(query.data.q) });
  });

  app.get('/lieux/autour', { preHandler: app.requireAuth }, async (request, reply) => {
    const query = z
      .object({ lat: z.coerce.number().min(-90).max(90), lng: z.coerce.number().min(-180).max(180) })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'position invalide' });
    return reply.send(autourDe({ lat: query.data.lat, lng: query.data.lng }));
  });
}
