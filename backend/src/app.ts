import Fastify, { type FastifyInstance } from 'fastify';
import { env, isProduction } from './config/env.js';
import { registerAuth } from './plugins/auth.js';
import { authHookRoutes } from './routes/authHook.js';
import { cartRoutes } from './routes/cart.js';
import { catalogRoutes } from './routes/catalog.js';
import { orderRoutes } from './routes/orders.js';
import { CONTRACT_VERSION } from './components/builders.js';

/**
 * Construction de l'application, séparée du démarrage : les tests ont besoin
 * d'une instance sans port ouvert, via `app.inject()`.
 */
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

  app.get('/health', async () => ({ status: 'ok', contract: CONTRACT_VERSION }));

  await app.register(authHookRoutes);
  await app.register(catalogRoutes);
  await app.register(cartRoutes);
  await app.register(orderRoutes);

  // Phase 4 : await app.register(chatRoutes);

  return app;
}
