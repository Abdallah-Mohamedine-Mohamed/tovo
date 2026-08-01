import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { SupabaseClient } from '@supabase/supabase-js';
import { userClient } from '../services/supabase.js';

/**
 * Extraction et vérification du JWT Supabase.
 *
 * On ne décode pas le token nous-mêmes : on le passe à Supabase, qui le valide
 * et nous rend l'utilisateur. Un token expiré ou forgé échoue là.
 *
 * Le client porté par `request.supabase` utilise le JWT de l'utilisateur.
 * C'est lui — et jamais serviceClient() — qui exécute les outils de l'IA, pour
 * que la RLS reste active de bout en bout.
 *
 * Appelé directement sur l'instance racine (pas via register) pour que le
 * décorateur soit visible de toutes les routes, sans dépendre de
 * fastify-plugin.
 */

export interface AuthenticatedUser {
  id: string;
  phone: string | null;
  role: string;
}

declare module 'fastify' {
  interface FastifyRequest {
    rawBody?: string;
    user?: AuthenticatedUser;
    supabase?: SupabaseClient;
  }

  interface FastifyInstance {
    requireAuth: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

function bearerToken(request: FastifyRequest): string | null {
  const header = request.headers.authorization;
  if (!header?.startsWith('Bearer ')) return null;
  const token = header.slice(7).trim();
  return token.length > 0 ? token : null;
}

export function registerAuth(app: FastifyInstance): void {
  /**
   * À déclarer en preHandler sur les routes protégées :
   *   app.post('/chat', { preHandler: app.requireAuth }, handler)
   */
  app.decorate('requireAuth', async (request: FastifyRequest, reply: FastifyReply) => {
    const token = bearerToken(request);
    if (!token) {
      await reply.code(401).send({ error: 'authentification requise' });
      return;
    }

    const client = userClient(token);
    const { data, error } = await client.auth.getUser();

    if (error || !data.user) {
      await reply.code(401).send({ error: 'session invalide' });
      return;
    }

    // Le rôle vit dans profiles, pas dans le JWT : un utilisateur ne doit pas
    // pouvoir se promouvoir en modifiant ses métadonnées d'inscription.
    const { data: profile } = await client
      .from('profiles')
      .select('role')
      .eq('id', data.user.id)
      .single();

    request.user = {
      id: data.user.id,
      phone: data.user.phone ?? null,
      role: (profile?.role as string | undefined) ?? 'client',
    };
    request.supabase = client;
  });
}
