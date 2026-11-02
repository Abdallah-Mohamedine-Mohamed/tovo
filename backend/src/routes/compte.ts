import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { serviceClient } from '../services/supabase.js';
import { pageLegale } from '../services/pagesLegales.js';

/**
 * Le compte du client : son profil, et sa suppression (02/11).
 *
 * La suppression depuis l'application est exigée par Apple et Google. Elle
 * se fait en deux temps : le client redemande un code (WhatsApp), le saisit,
 * et c'est seulement cette connexion toute fraîche qui autorise la
 * suppression — un téléphone prêté ou déverrouillé ne suffit pas.
 *
 * Ce qui part : le profil et, en cascade, adresses, conversations, panier,
 * jetons de notification. Ce qui reste : les commandes passées, sans
 * personne derrière (migration 0088) et sans repère d'adresse ni note.
 */

/** La connexion qui autorise la suppression doit dater de moins de 10 minutes. */
export const FENETRE_RECONFIRMATION_MS = 10 * 60_000;

/** Les commandes qui empêchent de partir : on ne supprime pas un client en cours de livraison. */
const STATUTS_TERMINES = ['delivered', 'cancelled'];

/** Une connexion assez récente pour autoriser la suppression ? */
export function reconfirmeRecemment(derniereConnexion: string | null | undefined, maintenant = Date.now()): boolean {
  if (!derniereConnexion) return false;
  const quand = Date.parse(derniereConnexion);
  return !Number.isNaN(quand) && maintenant - quand >= 0 && maintenant - quand < FENETRE_RECONFIRMATION_MS;
}

const nomSchema = z.object({ full_name: z.string().trim().min(2).max(60) });

export async function compteRoutes(app: FastifyInstance): Promise<void> {
  app.get('/me', { preHandler: app.requireAuth }, async (request, reply) => {
    const { data, error } = await request.supabase!
      .from('profiles').select('full_name, phone, role, created_at').eq('id', request.user!.id).maybeSingle();
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send({ ...(data ?? {}), phone: data?.phone ?? request.user!.phone });
  });

  app.patch('/me', { preHandler: app.requireAuth }, async (request, reply) => {
    const body = nomSchema.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: 'Un nom de 2 à 60 caractères.' });
    const { error } = await request.supabase!
      .from('profiles').update({ full_name: body.data.full_name }).eq('id', request.user!.id);
    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send({ full_name: body.data.full_name });
  });

  app.delete('/me', { preHandler: app.requireAuth }, async (request, reply) => {
    const moi = request.user!;
    // Une boutique ou un livreur a des comptes, des collectes, des courses
    // rattachés : leur départ passe par l'équipe, pas par un bouton.
    if (moi.role !== 'client') {
      return reply.code(409).send({
        code: 'role',
        error: 'Votre compte est lié à une boutique ou à des livraisons. Contactez Tovo au +227 76 76 20 20 pour le fermer.',
      });
    }
    const service = serviceClient();
    try {
      const { data: auth, error: erreurAuth } = await service.auth.admin.getUserById(moi.id);
      if (erreurAuth) throw erreurAuth;
      if (!reconfirmeRecemment(auth.user?.last_sign_in_at)) {
        return reply.code(403).send({ code: 'reconfirmer', error: 'Confirmez d’abord avec le code reçu.' });
      }

      const { data: commandes, error: erreurCommandes } = await service
        .from('orders').select('id, status').eq('user_id', moi.id);
      if (erreurCommandes) throw erreurCommandes;
      if ((commandes ?? []).some((c) => !STATUTS_TERMINES.includes(c.status as string))) {
        return reply.code(409).send({
          code: 'commande_en_cours',
          error: 'Une commande est en cours. Vous pourrez supprimer votre compte une fois livrée ou annulée.',
        });
      }

      // Les commandes restent, mais sans ce qui désigne la personne.
      if ((commandes ?? []).length) {
        const { error } = await service.from('orders')
          .update({ dropoff_hint: 'Adresse effacée', note: null, proof_photo_path: null })
          .eq('user_id', moi.id);
        if (error) throw error;
      }

      const { error: erreurSuppression } = await service.auth.admin.deleteUser(moi.id);
      if (erreurSuppression) throw erreurSuppression;
      // Le registre ne porte que la date et le nombre de commandes.
      await service.from('comptes_supprimes').insert({ commandes: (commandes ?? []).length });
      request.log.info({ commandes: (commandes ?? []).length }, 'compte supprimé par son titulaire');
      return reply.send({ supprime: true });
    } catch (error) {
      request.log.error({ err: error }, 'suppression de compte impossible');
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
  });

  // Les pages publiques demandées par les stores, et ouvertes depuis le profil.
  for (const page of ['confidentialite', 'conditions'] as const) {
    app.get(`/${page}`, async (_request, reply) => reply.type('text/html; charset=utf-8').send(pageLegale(page)));
  }
}
