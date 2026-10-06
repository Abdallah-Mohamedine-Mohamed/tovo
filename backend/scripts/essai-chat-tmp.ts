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
const fois = Number(process.env.FOIS ?? 1);
try {
  for (const phrase of process.argv.slice(2)) {
    for (let i = 0; i < fois; i++) {
      const client = await createUser('client');
      const res = await app.inject({
        method: 'POST', url: '/chat', headers: { authorization: `Bearer ${client.accessToken}` },
        payload: { client_message_id: randomUUID(), context: { lat: 13.52, lng: 2.11 }, text: phrase },
      });
      const j = res.json() as { content?: string; components?: Array<{ type: string; data: Record<string, unknown> }> };
      console.log(`\n« ${phrase} » → ${res.statusCode}\n  ${j.content}`);
      const cartes = (j.components ?? []).filter((c) => c.type === "merchant_card").map((c) => String(c.data.name ?? (c.data.merchant as any)?.name ?? "?"));
      if (cartes.length) console.log(`  [merchant_card ×${cartes.length}] ${cartes.slice(0, 6).join(" ; ")}`);
      for (const c of (j.components ?? []).filter((c) => c.type !== "merchant_card")) {
        const items = Array.isArray(c.data.items) ? c.data.items as Array<Record<string, unknown>> : [];
        console.log(`  [${c.type}] ${items.slice(0, 6).map((x) => `${x.name ?? x.nom}${x.quartier ? ` (${x.quartier})` : ''}`).join(' ; ')}`);
      }
    }
  }
} finally {
  await cleanup();
  await app.close();
}
