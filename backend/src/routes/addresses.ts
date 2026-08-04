import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';

/**
 * Adresses enregistrées.
 *
 * À Niamey, l'adresse postale n'existe pas : on se repère par des indices
 * (« Yantala, derrière la pharmacie Al Nour »). Retaper cet indice à chaque
 * commande est la friction quotidienne la plus évitable de l'application.
 *
 * Le repère écrit compte autant que les coordonnées : c'est lui que le
 * livreur lit, et lui qui l'amène à la bonne porte quand le GPS le pose au
 * milieu du quartier.
 */

const saveSchema = z.object({
  label: z.string().max(60).default('Adresse'),
  text_hint: z.string().min(1).max(300),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  is_default: z.boolean().default(false),
});

export async function addressRoutes(app: FastifyInstance): Promise<void> {
  app.get('/addresses', { preHandler: app.requireAuth }, async (request, reply) => {
    const { data, error } = await request.supabase!.rpc('my_addresses');
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send({ addresses: data ?? [] });
  });

  app.post('/addresses', { preHandler: app.requireAuth }, async (request, reply) => {
    const body = saveSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const { data, error } = await request.supabase!.rpc('save_address', {
      p_label: body.data.label,
      p_text_hint: body.data.text_hint,
      p_lat: body.data.lat,
      p_lng: body.data.lng,
      p_is_default: body.data.is_default,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply
      .code(201)
      .send({ ...envelope('Adresse enregistrée.', []), address_id: data });
  });

  app.delete('/addresses/:addressId', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ addressId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    // La RLS limite déjà la suppression au propriétaire : pas de vérification
    // supplémentaire ici, elle ne ferait que dupliquer la règle.
    const { error } = await request.supabase!
      .from('addresses')
      .delete()
      .eq('id', params.data.addressId);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send(envelope('Adresse supprimée.', []));
  });

  app.post(
    '/addresses/:addressId/default',
    { preHandler: app.requireAuth },
    async (request, reply) => {
      const params = z.object({ addressId: z.string().uuid() }).safeParse(request.params);
      if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

      // Le trigger `single_default_address` retire le défaut des autres :
      // le faire ici aussi laisserait deux écritures se contredire selon
      // qui passe par PostgREST directement.
      const { error } = await request.supabase!
        .from('addresses')
        .update({ is_default: true })
        .eq('id', params.data.addressId);

      if (error) {
        const failure = toHttpFailure(error);
        return reply.code(failure.status).send(failure.body);
      }
      return reply.send(envelope('Adresse par défaut mise à jour.', []));
    },
  );
}
