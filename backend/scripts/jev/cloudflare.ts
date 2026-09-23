/**
 * Jev est-il lent, ou est-ce OpenRouter ? Même modèle, deux chemins :
 *   - OpenRouter (bêta, relais aux États-Unis) ;
 *   - Cloudflare Workers AI (typesafe/jev, servi par le réseau Cloudflare).
 *
 *   npm run jev:cloudflare
 *
 * Il faut dans backend/.env :
 *   CLOUDFLARE_ACCOUNT_ID=…   (tableau de bord Cloudflare, colonne de droite)
 *   CLOUDFLARE_API_TOKEN=…    (My Profile → API Tokens → « Workers AI » en lecture)
 *
 * Les appels sont ALTERNÉS (un OpenRouter, un Cloudflare…) pour que les deux
 * subissent les mêmes conditions de réseau. N'envoie que les phrases de test.
 */
import { INTENTIONS, classerIntention, type Intention } from '../../src/ai/jev.js';
import { PHRASES } from './phrases.js';

const COMPTE = process.env.CLOUDFLARE_ACCOUNT_ID;
const JETON = process.env.CLOUDFLARE_API_TOKEN;
const CLE_OR = process.env.OPENROUTER_API_KEY;
if (!COMPTE || !JETON) {
  console.log('CLOUDFLARE_ACCOUNT_ID et CLOUDFLARE_API_TOKEN manquants dans backend/.env (voir en tête du fichier).');
  process.exit(0);
}

async function viaCloudflare(message: string): Promise<{ choix: Intention | null; ms: number; erreur?: string }> {
  const debut = performance.now();
  try {
    const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${COMPTE}/ai/run`, {
      method: 'POST',
      headers: { authorization: `Bearer ${JETON}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        model: 'typesafe/jev',
        input: {
          state: { message },
          questions: {
            intention: {
              type: 'choice',
              instructions: 'Message d’un client à Tovo, une application de livraison à Niamey (Niger) : repas, courses et colis. Que veut-il faire ?',
              criteria: INTENTIONS,
            },
          },
        },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const ms = performance.now() - debut;
    const corps = (await res.json()) as Record<string, unknown>;
    // L'API REST enveloppe parfois la réponse dans `result`.
    const reponse = ((corps.result as Record<string, unknown> | undefined) ?? corps) as { answers?: { intention?: { choice?: string } } };
    if (!res.ok) return { choix: null, ms, erreur: `${res.status} ${JSON.stringify(corps.errors ?? corps).slice(0, 200)}` };
    return { choix: (reponse.answers?.intention?.choice as Intention | undefined) ?? null, ms };
  } catch (cause) {
    return { choix: null, ms: performance.now() - debut, erreur: String(cause) };
  }
}

const cf: number[] = [], or: number[] = [];
let accord = 0, erreursCf = 0, erreursOr = 0, premiereErreur = '';
for (const [message] of PHRASES.slice(0, 30)) {
  const a = await viaCloudflare(message);
  if (a.erreur) { erreursCf++; premiereErreur ||= a.erreur; } else cf.push(a.ms);
  if (CLE_OR) {
    const b = await classerIntention(message, { cle: CLE_OR, modele: 'typesafe/jev-1.13', delaiMs: 15_000 });
    if (b.erreur) erreursOr++; else or.push(b.ms);
    if (!a.erreur && !b.erreur && a.choix === b.choix) accord++;
  }
}

const stats = (t: number[]) => {
  const s = [...t].sort((x, y) => x - y);
  const c = (p: number) => Math.round(s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] ?? 0);
  return `médiane ${c(50)} ms · p90 ${c(90)} ms · max ${c(100)} ms · sous 800 ms : ${s.filter((x) => x < 800).length}/${s.length}`;
};
console.log(`Cloudflare : ${stats(cf)}${erreursCf ? ` · ${erreursCf} erreurs (${premiereErreur})` : ''}`);
if (CLE_OR) {
  console.log(`OpenRouter : ${stats(or)}${erreursOr ? ` · ${erreursOr} erreurs` : ''}`);
  console.log(`Même décision sur les deux chemins : ${accord}/${Math.min(cf.length, or.length)}`);
}
