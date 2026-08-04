import Fastify, { type FastifyInstance } from 'fastify';
import { env, isProduction } from './config/env.js';
import { registerAuth } from './plugins/auth.js';
import { attachObservability, initObservability } from './lib/observability.js';
import { authHookRoutes } from './routes/authHook.js';
import { cartRoutes } from './routes/cart.js';
import { catalogRoutes } from './routes/catalog.js';
import { fulfillmentRoutes } from './routes/fulfillment.js';
import { chatRoutes } from './routes/chat.js';
import { merchantCatalogRoutes } from './routes/merchantCatalog.js';
import { orderRoutes } from './routes/orders.js';
import { nitaWebhookRoutes } from './routes/nitaWebhook.js';
import { addressRoutes } from './routes/addresses.js';
import { reviewRoutes } from './routes/reviews.js';
import { externalOfferRoutes } from './routes/externalOffers.js';
import { CONTRACT_VERSION } from './components/builders.js';
import { registerDispatchProcessor } from './services/dispatch.js';
import { registerSweepProcessor } from './services/sweep.js';
import { registerIndexProcessor } from './services/indexer.js';
import { queuesEnabled } from './services/queue.js';
import { pushStatus } from './services/notifications.js';

/**
 * Construction de l'application, séparée du démarrage : les tests ont besoin
 * d'une instance sans port ouvert, via `app.inject()`.
 */
// Avant toute construction : Sentry doit intercepter jusqu’aux erreurs de
// démarrage.
initObservability();

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: {
      level: env.LOG_LEVEL,
      ...(isProduction ? {} : { transport: { target: 'pino-pretty' } }),
      redact: {
        // Un OTP ou un JWT dans les logs, c'est une faille, pas une trace.
        paths: ['req.headers.authorization', 'body.sms.otp', 'sms.otp'],
        censor: '[caché]',
      },
    },
    trustProxy: true,
    bodyLimit: 1_048_576, // 1 Mo. Les images passent par Storage, pas par ici.
  });

  /**
   * Le hook d'auth Supabase est signé sur le corps brut : un JSON reparsé
   * puis re-sérialisé ne produit pas la même signature. On conserve donc la
   * chaîne d'origine.
   */
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (request, body, done) => {
    const raw = typeof body === 'string' ? body : body.toString('utf8');
    request.rawBody = raw;
    if (raw.length === 0) {
      done(null, {});
      return;
    }
    try {
      done(null, JSON.parse(raw) as unknown);
    } catch (error) {
      done(error as Error, undefined);
    }
  });

  registerAuth(app);
  attachObservability(app);

  // Enregistre l'exécuteur du dispatch. Le worker BullMQ, lui, ne démarre
  // que dans index.ts : une instance construite pour les tests ne doit pas
  // ouvrir de connexion Redis.
  registerDispatchProcessor();
  registerSweepProcessor();
  registerIndexProcessor();
  if (!queuesEnabled) {
    app.log.warn(
      "REDIS_URL absent : le dispatch s'exécute en direct, sans réessai. " +
        'Acceptable en développement, pas en production.',
    );
  }

  const fcm = pushStatus();
  if (fcm.enabled) {
    app.log.info({ projectId: fcm.projectId }, 'FCM configuré : les notifications partiront réellement.');
  } else {
    app.log.warn(
      { cause: fcm.error },
      'FCM non configuré : les notifications seront seulement journalisées.',
    );
  }

  app.get('/health', async () => ({ status: 'ok', contract: CONTRACT_VERSION }));

  await app.register(authHookRoutes);
  await app.register(catalogRoutes);
  await app.register(cartRoutes);
  await app.register(orderRoutes);
  await app.register(fulfillmentRoutes);
  await app.register(chatRoutes);
  await app.register(merchantCatalogRoutes);
  await app.register(nitaWebhookRoutes);
  await app.register(addressRoutes);
  await app.register(reviewRoutes);
  await app.register(externalOfferRoutes);

  return app;
}
