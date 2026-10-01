/**
 * Retrouve le point de terminaison du trieur entraîné (dernier réglage réussi).
 *
 *   VERTEX_CLE_FICHIER=<clé.json> npx tsx scripts/vertex/trouver.ts
 */
import { readFileSync } from 'node:fs';
import { jetonGoogle } from '../../src/ai/trieurEntraine.js';

const compte = JSON.parse(readFileSync(process.env.VERTEX_CLE_FICHIER!, 'utf8'));
const jeton = await jetonGoogle(compte)();
const r = await fetch(`https://us-central1-aiplatform.googleapis.com/v1/projects/${compte.project_id}/locations/us-central1/tuningJobs`, {
  headers: { authorization: `Bearer ${jeton}` },
});
const j = (await r.json()) as {
  tuningJobs?: Array<{ tunedModelDisplayName?: string; state?: string; tunedModel?: { endpoint?: string; model?: string } }>;
  error?: { message?: string };
};
if (!r.ok) throw new Error(`${r.status} ${j.error?.message ?? ''}`);
for (const t of j.tuningJobs ?? []) console.log(t.tunedModelDisplayName, t.state, t.tunedModel?.endpoint ?? '(pas de point de terminaison)');
