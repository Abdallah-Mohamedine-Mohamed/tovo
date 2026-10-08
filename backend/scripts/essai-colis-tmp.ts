import { randomUUID } from 'node:crypto';
process.env.REDIS_URL = '';
process.env.LOG_LEVEL = 'error';
const { buildApp } = await import('../src/app.js');
const { cleanup, createUser } = await import('../tests/rls/harness.js');
const { registerProcessor } = await import('../src/services/queue.js');
const { DISPATCH_QUEUE } = await import('../src/services/dispatch.js');
const app = await buildApp();
await app.ready();
registerProcessor(DISPATCH_QUEUE, async () => undefined);
try {
  const client = await createUser('client');
  for (const [texte, flux] of [['Je veux envoyer un colis', false], ['Je veux envoyer un colis', true], ['Je veux un livreur', true]] as const) {
    const debut = Date.now();
    const res = await app.inject({ method: 'POST', url: '/chat',
      headers: { authorization: `Bearer ${client.accessToken}`, ...(flux ? { accept: 'application/x-ndjson' } : {}) },
      payload: { client_message_id: randomUUID(), context: { lat: 13.5297, lng: 2.0886 }, text: texte } });
    const corps = res.body;
    const lignes = flux ? corps.trim().split('\n') : [];
    console.log(`« ${texte} » ${flux ? '(flux)' : ''} → ${res.statusCode} en ${Date.now() - debut} ms`);
    if (flux) console.log('  événements :', lignes.map((l) => { try { return JSON.parse(l).type; } catch { return 'ILLISIBLE: ' + l.slice(0, 80); } }).join(', '), '| dernière :', lignes.at(-1)?.slice(0, 200));
    else console.log('  ', corps.slice(0, 300));
  }
} finally { await cleanup(); await app.close(); }
