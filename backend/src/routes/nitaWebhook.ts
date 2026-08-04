import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { env, paiementMobileActif } from '../config/env.js';
import { verifierPaiement } from '../services/payments.js';

/**
 * Rappel de Nita après un paiement au guichet ou depuis MYNITA.
 *
 * Nita ne signe pas ce rappel : aucune empreinte, aucun secret partagé dans
 * les en-têtes. Deux conséquences, et elles gouvernent ce fichier.
 *
 * D'abord le secret est dans le CHEMIN de l'URL de rappel, ce que Nita
 * transmet tel quel. Ça écarte les appels de passants, sans plus : une URL
 * peut fuiter par un journal ou une capture réseau.
 *
 * Ensuite, et c'est l'essentiel : **le corps du message n'est jamais cru**.
 * Il sert seulement de signal. L'état réel est demandé à Nita par un appel
 * sortant que nous initions. Sans cela, quiconque devinerait l'URL se ferait
 * livrer sans payer.
 */

const corpsSchema = z
  .object({
    requestId: z.string().uuid().optional(),
    codeAchat: z.string().optional(),
  })
  .passthrough();

export async function nitaWebhookRoutes(app: FastifyInstance): Promise<void> {
  app.post('/webhooks/nita/:secret', async (request, reply) => {
    if (!paiementMobileActif || !env.NITA_WEBHOOK_SECRET) {
      return reply.code(404).send({ error: 'introuvable' });
    }

    const params = z.object({ secret: z.string() }).safeParse(request.params);
    if (!params.success || params.data.secret !== env.NITA_WEBHOOK_SECRET) {
      // Volontairement muet sur la raison : un message précis aiderait à
      // deviner le secret par tâtonnement.
      return reply.code(404).send({ error: 'introuvable' });
    }

    const corps = corpsSchema.safeParse(request.body);
    const orderId = corps.success ? corps.data.requestId : undefined;

    if (!orderId) {
      // On répond 200 quand même : renvoyer une erreur ferait réessayer Nita
      // en boucle pour un message que nous ne saurons jamais traiter.
      request.log.warn({ body: request.body }, 'callback Nita sans requestId exploitable');
      return reply.send({ received: true });
    }

    try {
      const etat = await verifierPaiement(orderId, { adresseIp: request.ip });
      request.log.info({ orderId, etat }, 'callback Nita traité');
    } catch (cause) {
      // Échec de notre côté : on le signale à Nita pour qu'il rappelle. Le
      // balayage périodique rattraperait de toute façon.
      request.log.error({ cause, orderId }, 'vérification du paiement impossible');
      return reply.code(503).send({ received: false });
    }

    return reply.send({ received: true });
  });
}
