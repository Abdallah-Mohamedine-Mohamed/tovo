/**
 * Prépare l'entraînement (affinage supervisé) du trieur sur Vertex AI.
 *
 *   npm run vertex:exporter -- <dossier>
 *
 * Écrit <dossier>/entrainement.jsonl et <dossier>/validation.jsonl au format
 * Vertex (systemInstruction + contents). Chaque exemple montre au modèle
 * EXACTEMENT ce qu'il voit en production (CONSIGNE_CERVEAU, messagePourCerveau)
 * et la réponse attendue {"intention", "sur"}.
 *
 * - Les 203 phrases de référence (JEU) n'y entrent jamais : elles restent
 *   l'examen commun avec les autres modèles.
 * - « social » est plafonné : la banque en compte beaucoup (surtout MASSIVE),
 *   et un modèle entraîné dessus répondrait trop souvent « social ».
 * - « sur » vaut true partout : les phrases ambiguës ont été écartées de la
 *   banque. À surveiller au banc (colonne Tuiles).
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { INTENTIONS } from '../../src/ai/jev.js';
import { messagePourCerveau } from '../../src/ai/decideur.js';
import { CONSIGNE_COURTE } from '../../src/ai/trieurEntraine.js';
import { JEU } from '../../src/ai/banc/jeu.js';
import { toutLire } from '../../src/ai/banc/lire.js';
import { serviceClient } from '../../src/services/supabase.js';

const dossier = process.argv[2] ?? 'vertex-essai';

// Consigne COURTE (option B, 30/09) : le modèle apprend la tâche par les
// exemples, pas en relisant les règles. La longue CONSIGNE_CERVEAU répétée sur
// chaque exemple coûtait ~15× plus cher à l'entraînement. Partagée avec
// l'appel (src/ai/trieurEntraine.ts) : les deux doivent rester identiques.
const PLAFOND_SOCIAL = 350;
const PART_VALIDATION = 0.1;

// Tirage reproductible : la même graine donne les mêmes fichiers.
let graine = 20260930;
const hasard = () => ((graine = (graine * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const melanger = <T>(t: T[]) => {
  for (let i = t.length - 1; i > 0; i--) {
    const j = Math.floor(hasard() * (i + 1));
    [t[i], t[j]] = [t[j]!, t[i]!];
  }
  return t;
};

const db = serviceClient();
type Ligne = { texte: string; avant: string | null; attendu: string; reponse?: string | null };
const lecture = await toutLire((de, a) => db.from('banc_cas')
  .select('texte, avant, attendu, reponse').eq('statut', 'valide').order('id').range(de, a));
if (lecture.error) throw new Error(lecture.error.message);

const reference = new Set(JEU.map((c) => c.texte.trim().toLowerCase()));
const vus = new Set<string>();
const cas = ((lecture.data ?? []) as unknown as Ligne[]).filter((c) => {
  const cle = `${c.avant ?? ''}|${c.texte.trim().toLowerCase()}`;
  const garder = (c.reponse ?? 'intention') === 'intention' && c.attendu in INTENTIONS
    && !reference.has(c.texte.trim().toLowerCase()) && !vus.has(cle);
  vus.add(cle);
  return garder;
});

const social = melanger(cas.filter((c) => c.attendu === 'social')).slice(0, PLAFOND_SOCIAL);
const retenus = melanger([...cas.filter((c) => c.attendu !== 'social'), ...social]);

const exemple = (c: Ligne) => JSON.stringify({
  systemInstruction: { role: 'system', parts: [{ text: CONSIGNE_COURTE }] },
  contents: [
    { role: 'user', parts: [{ text: messagePourCerveau(c.texte, { avant: c.avant }) }] },
    { role: 'model', parts: [{ text: JSON.stringify({ intention: c.attendu, sur: true }) }] },
  ],
});

const nValidation = Math.round(retenus.length * PART_VALIDATION);
mkdirSync(dossier, { recursive: true });
writeFileSync(join(dossier, 'validation.jsonl'), retenus.slice(0, nValidation).map(exemple).join('\n') + '\n');
writeFileSync(join(dossier, 'entrainement.jsonl'), retenus.slice(nValidation).map(exemple).join('\n') + '\n');

const compte: Record<string, number> = {};
for (const c of retenus) compte[c.attendu] = (compte[c.attendu] ?? 0) + 1;
console.log(`${retenus.length - nValidation} pour l'entraînement, ${nValidation} pour la validation → ${dossier}`);
console.log(compte);
