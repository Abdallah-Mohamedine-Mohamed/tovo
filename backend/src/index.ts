import { buildApp } from './app.js';
import { env } from './config/env.js';
import { startDispatchWorker } from './services/dispatch.js';
import { startSweep } from './services/sweep.js';
import { startIndexer } from './services/indexer.js';
import { closeQueues } from './services/queue.js';

const app = await buildApp();

// Le worker ne tourne que dans le vrai serveur, jamais dans les tests.
startDispatchWorker();

// Balayage des commandes prêtes restées sans livreur. Un échec ici ne doit
// pas empêcher le serveur de démarrer : c'est un filet, pas un organe vital.
startSweep().catch((cause) => app.log.error(cause, 'balayage du dispatch indisponible'));
startIndexer().catch((cause) => app.log.error(cause, 'indexation des produits indisponible'));

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    app.log.info({ signal }, 'arrêt en cours');
    void app.close().then(closeQueues).then(() => process.exit(0));
  });
}

try {
  await app.listen({ port: env.PORT, host: '0.0.0.0' });
} catch (error) {
  app.log.fatal(error, 'démarrage impossible');
  process.exit(1);
}
