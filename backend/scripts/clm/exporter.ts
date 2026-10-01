/**
 * Exporte le banc IA pour l'essai de CLM-8B (Stanford/NVIDIA, sur Qwen3),
 * un modèle « System One » qu'il faut faire tourner sur une carte graphique
 * louée — donc hors de ce serveur.
 *
 *   npm run clm:exporter -- <dossier>
 *
 * Écrit <dossier>/banc.json : les 13 intentions (mêmes descriptions que
 * Jev), les actions coûteuses, le jeu de référence (JEU) et les phrases
 * validées de banc_cas, et le dernier score du cerveau Gemini pour
 * comparer. Aucune clé, aucune donnée client autre que les phrases du banc.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { INTENTIONS } from '../../src/ai/jev.js';
import { COUTEUSES, JEU } from '../../src/ai/banc/jeu.js';
import { toutLire } from '../../src/ai/banc/lire.js';
import { serviceClient } from '../../src/services/supabase.js';

const dossier = process.argv[2] ?? 'clm-essai';
mkdirSync(dossier, { recursive: true });

const db = serviceClient();
type Ligne = { texte: string; avant: string | null; attendu: string; origine: string; reponse?: string | null };
let lecture = await toutLire((de, a) => db.from('banc_cas')
  .select('texte, avant, attendu, origine, reponse').eq('statut', 'valide').order('id').range(de, a));
if (lecture.error) {
  lecture = await toutLire((de, a) => db.from('banc_cas')
    .select('texte, avant, attendu, origine').eq('statut', 'valide').order('id').range(de, a)) as typeof lecture;
}
const base = (lecture.data ?? []) as unknown as Ligne[];

const { data: passages } = await db.from('banc_passages').select('rapport, cree_le')
  .order('cree_le', { ascending: false }).limit(40);
const dernierExamen = (passages ?? [])
  .map((p) => (p as { rapport: { examen?: unknown; passage?: string } }).rapport)
  .find((r) => r?.examen);

const cas = [
  ...JEU.map((c) => ({
    texte: c.texte, avant: c.avant ?? null, attendu: c.attendu, origine: c.source,
    reponse: 'intention', reference: true, contexte: Boolean(c.contexte),
  })),
  ...base.map((c) => ({
    texte: c.texte, avant: c.avant, attendu: c.attendu, origine: c.origine,
    reponse: c.reponse ?? 'intention', reference: false, contexte: false,
  })),
];

writeFileSync(join(dossier, 'banc.json'), JSON.stringify({
  consigne: 'Message d’un client à Tovo, une application de livraison à Niamey (Niger) : '
    + 'repas, courses et colis. Que veut-il faire ?',
  intentions: INTENTIONS,
  couteuses: [...COUTEUSES],
  // « livreur » et « colis » : la même course, deux mots (memeSens).
  equivalences: [['livreur', 'colis']],
  gemini_dernier_examen: dernierExamen ?? null,
  cas,
}, null, 1));

console.log(`${cas.length} phrases (${JEU.length} de référence, ${base.length} du banc) → ${join(dossier, 'banc.json')}`);
