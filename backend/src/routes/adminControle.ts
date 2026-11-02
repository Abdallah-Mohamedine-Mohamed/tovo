import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { toHttpFailure } from '../lib/errors.js';
import { construireSalle, debutDuJourANiamey, type DonneesBrutes } from '../services/salleControle.js';

/**
 * La salle de contrôle de l'admin (02/11) : une lecture (migration 0089),
 * les règles dans services/salleControle.ts. L'écran la relit toutes les
 * 15 secondes, et dès qu'une commande change.
 */
export async function adminControleRoutes(app: FastifyInstance): Promise<void> {
  const exigerAdmin = async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.user?.role !== 'admin') {
      return reply.code(403).send({ error: 'réservé à l’administration' });
    }
  };

  app.get('/admin/controle', { preHandler: [app.requireAuth, exigerAdmin] }, async (request, reply) => {
    const maintenant = Date.now();
    const debutJour = debutDuJourANiamey(maintenant);
    const { data, error } = await request.supabase!.rpc('admin_salle_controle', {
      p_depuis: new Date(debutJour).toISOString(),
    });
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send({ le: new Date(maintenant).toISOString(), ...construireSalle(data as DonneesBrutes, maintenant, debutJour) });
  });
}
