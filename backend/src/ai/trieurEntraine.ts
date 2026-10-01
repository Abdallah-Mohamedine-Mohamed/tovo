import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { INTENTIONS, type Intention } from './jev.js';
import { lireDecision, messagePourCerveau, type ContexteCerveau } from './decideur.js';

/**
 * Le trieur ENTRAÎNÉ sur Vertex AI (affinage supervisé de gemini-3.1-flash-lite,
 * 30/09, scripts/vertex/exporter.ts).
 *
 * Il a appris la tâche sur ~1 800 phrases validées avec cette consigne COURTE :
 * il doit être appelé avec elle, mot pour mot, et le même format de message
 * que le cerveau (messagePourCerveau).
 *
 * Pas encore branché en production : le banc le mesure d'abord.
 */
export const CONSIGNE_COURTE = 'Tovo, livraison à Niamey. Intention du message du client parmi : '
  + `${Object.keys(INTENTIONS).join(', ')}. Réponds en JSON {"intention": "<clé>", "sur": true|false}.`;

interface CompteDeService { client_email: string; private_key: string; project_id: string }

const b64url = (s: string | Buffer) => Buffer.from(s).toString('base64url');

/**
 * Un jeton d'accès Google (1 h) à partir de la clé du compte de service :
 * JWT signé RS256, échangé contre un jeton OAuth. Mis en cache jusqu'à 5 min
 * avant son expiration.
 */
export function jetonGoogle(compte: CompteDeService) {
  let cache: { jeton: string; expire: number } | null = null;
  return async () => {
    if (cache && cache.expire - Date.now() > 5 * 60_000) return cache.jeton;
    const maintenant = Math.floor(Date.now() / 1000);
    const corps = `${b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64url(JSON.stringify({
      iss: compte.client_email,
      scope: 'https://www.googleapis.com/auth/cloud-platform',
      aud: 'https://oauth2.googleapis.com/token',
      iat: maintenant,
      exp: maintenant + 3600,
    }))}`;
    const signature = createSign('RSA-SHA256').update(corps).sign(compte.private_key);
    const r = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${corps}.${b64url(signature)}`,
      }),
    });
    const j = (await r.json()) as { access_token?: string; expires_in?: number; error_description?: string };
    if (!r.ok || !j.access_token) throw new Error(`jeton Google refusé : ${j.error_description ?? r.status}`);
    cache = { jeton: j.access_token, expire: Date.now() + (j.expires_in ?? 3600) * 1000 };
    return cache.jeton;
  };
}

/**
 * Interroge le trieur entraîné.
 * @param cheminCle chemin du fichier JSON de la clé du compte de service
 * @param pointDeTerminaison « projects/…/locations/us-central1/endpoints/… »
 */
export function trieurEntraine(cheminCle: string, pointDeTerminaison: string) {
  const compte = JSON.parse(readFileSync(cheminCle, 'utf8')) as CompteDeService;
  const jeton = jetonGoogle(compte);
  const region = pointDeTerminaison.match(/locations\/([^/]+)/)?.[1] ?? 'us-central1';
  // Le modèle réglé est servi dans la multi-région « us » : son hôte est
  // aiplatform.us.rep (vérifié le 30/09 ; us-aiplatform est refusé).
  const hote = region === 'us' || region === 'eu' ? `aiplatform.${region}.rep.googleapis.com` : `${region}-aiplatform.googleapis.com`;
  return async (message: string, contexte: ContexteCerveau = {}, signal?: AbortSignal)
    : Promise<{ intention: Intention; sur: boolean }> => {
    const r = await fetch(`https://${hote}/v1/${pointDeTerminaison}:generateContent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${await jeton()}` },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: CONSIGNE_COURTE }] },
        contents: [{ role: 'user', parts: [{ text: messagePourCerveau(message, contexte.avant ? { avant: contexte.avant } : {}) }] }],
        generationConfig: { temperature: 0, maxOutputTokens: 256, thinkingConfig: { thinkingBudget: 0 } },
      }),
      signal: signal ?? AbortSignal.timeout(20_000),
    });
    const corps = (await r.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
      error?: { message?: string };
    };
    if (!r.ok) throw new Error(`trieur entraîné ${r.status} ${corps.error?.message?.slice(0, 160) ?? ''}`);
    const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
    const d = lireDecision(texte);
    if (!d) throw new Error(`trieur entraîné : réponse illisible (${texte.slice(0, 80)})`);
    return d;
  };
}
