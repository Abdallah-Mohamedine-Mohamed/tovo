import * as Sentry from '@sentry/node';
import type { FastifyInstance } from 'fastify';
import { env, isProduction } from '../config/env.js';

/**
 * Observabilité.
 *
 * On ne peut pas exploiter un service de livraison en aveugle. Quand un
 * boutiquier appelle pour dire que « ça ne marche pas », il faut pouvoir
 * regarder ce qui s'est passé, pas deviner.
 *
 * Ce qui NE DOIT PAS partir chez Sentry :
 *   - les jetons d'authentification,
 *   - les codes OTP,
 *   - les numéros de téléphone et les repères d'adresse.
 *
 * Un repère de livraison — « derrière la pharmacie Al Nour » — identifie une
 * personne aussi sûrement qu'un nom. Le filtre ci-dessous les retire avant
 * l'envoi.
 */

export const observabilityEnabled = Boolean(env.SENTRY_DSN);

const CHAMPS_SENSIBLES = new Set([
  'authorization',
  'apikey',
  'token',
  'access_token',
  'refresh_token',
  'otp',
  'phone',
  'password',
  'dropoff_hint',
  'pickup_hint',
  'client_email',
  'private_key',
]);

function nettoyer(valeur: unknown, profondeur = 0): unknown {
  if (profondeur > 6) return '[trop profond]';
  if (Array.isArray(valeur)) return valeur.map((v) => nettoyer(v, profondeur + 1));

  if (valeur && typeof valeur === 'object') {
    return Object.fromEntries(
      Object.entries(valeur as Record<string, unknown>).map(([cle, v]) => [
        cle,
        CHAMPS_SENSIBLES.has(cle.toLowerCase()) ? '[caché]' : nettoyer(v, profondeur + 1),
      ]),
    );
  }

  return valeur;
}

export function initObservability(): void {
  if (!env.SENTRY_DSN) return;

  Sentry.init({
    dsn: env.SENTRY_DSN,
    environment: env.NODE_ENV,
    // Un échantillon suffit à voir les tendances de performance, et évite
    // de payer pour la trace de chaque ping de position — appelé toutes les
    // dix secondes par livreur.
    tracesSampleRate: isProduction ? 0.1 : 0,
    sendDefaultPii: false,
    beforeSend(event) {
      if (event.request) {
        event.request.headers = nettoyer(event.request.headers) as Record<string, string>;
        event.request.data = nettoyer(event.request.data);
        delete event.request.cookies;
      }
      if (event.extra) event.extra = nettoyer(event.extra) as Record<string, unknown>;
      return event;
    },
  });
}

/**
 * Branche Sentry sur Fastify.
 *
 * On capture les 5xx et les exceptions non gérées. Les 4xx sont des refus
 * normaux — un panier vide, une option manquante — et les remonter noierait
 * les vraies pannes.
 */
export function attachObservability(app: FastifyInstance): void {
  if (!observabilityEnabled) {
    app.log.warn('SENTRY_DSN absent : aucune remontée d’erreur.');
    return;
  }

  app.addHook('onError', async (request, _reply, erreur) => {
    Sentry.withScope((scope) => {
      scope.setTag('route', request.routeOptions.url ?? request.url);
      scope.setTag('method', request.method);
      // L'identifiant de l'utilisateur, pas son numéro : de quoi retrouver
      // la trace sans stocker de donnée personnelle.
      if (request.user?.id) scope.setUser({ id: request.user.id });
      Sentry.captureException(erreur);
    });
  });

  app.addHook('onResponse', async (request, reply) => {
    if (reply.statusCode < 500) return;
    Sentry.withScope((scope) => {
      scope.setLevel('error');
      scope.setTag('route', request.routeOptions.url ?? request.url);
      scope.setContext('reponse', { statusCode: reply.statusCode });
      Sentry.captureMessage(`${request.method} ${request.url} → ${reply.statusCode}`);
    });
  });
}

/**
 * Signale une anomalie métier qui n'est pas une exception.
 *
 * Exemple : le validateur rejette un composant parce que le modèle a inventé
 * un identifiant. Rien n'a planté, mais une hausse de ces rejets signale un
 * prompt qui dérive — et c'est le genre de dérive qu'on ne voit jamais sans
 * la mesurer.
 */
export function signaler(message: string, contexte?: Record<string, unknown>): void {
  if (!observabilityEnabled) return;
  Sentry.withScope((scope) => {
    scope.setLevel('warning');
    if (contexte) scope.setContext('detail', nettoyer(contexte) as Record<string, unknown>);
    Sentry.captureMessage(message);
  });
}
