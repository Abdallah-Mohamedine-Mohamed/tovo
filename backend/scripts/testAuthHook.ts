/**
 * Simule un appel du Send SMS Hook de Supabase.
 *
 * Reproduit exactement ce que GoTrue envoie : le corps, et les trois en-têtes
 * signés selon la norme Standard Webhooks. Sans ce test, on ne découvre un
 * défaut de vérification qu'en production, quand plus personne ne peut se
 * connecter — et l'erreur est un 401 opaque, sans indice sur sa cause.
 *
 *   npm run hook:test -- +22786967908 [http://localhost:3000]
 */
import { randomUUID } from 'node:crypto';
import { Webhook } from 'standardwebhooks';
import { env } from '../src/config/env.js';

const numero = process.argv[2];
const base = process.argv[3] ?? 'http://localhost:3000';
if (!numero) {
  console.error('Usage : npm run hook:test -- +22786967908 [url]');
  process.exit(1);
}
if (!env.AUTH_HOOK_SECRET) {
  console.error('AUTH_HOOK_SECRET absent : rien à signer.');
  process.exit(1);
}

const corps = JSON.stringify({
  user: { id: randomUUID(), phone: numero },
  sms: { otp: String(Math.floor(100000 + Math.random() * 900000)) },
});

// Le dashboard donne « v1,whsec_… » ; la librairie attend le base64 seul.
const webhook = new Webhook(env.AUTH_HOOK_SECRET.replace(/^v1,whsec_/, ''));
const id = `msg_${randomUUID()}`;
const horodatage = new Date();
const signature = webhook.sign(id, horodatage, corps);

const r = await fetch(`${base}/hooks/auth/send-sms`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    'webhook-id': id,
    'webhook-timestamp': String(Math.floor(horodatage.getTime() / 1000)),
    'webhook-signature': signature,
  },
  body: corps,
});

console.log(`${base} → ${r.status}`);
console.log(await r.text());
