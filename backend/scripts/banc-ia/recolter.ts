/**
 * Le banc qui grandit : récolte les VRAIES phrases récentes des clients qui
 * ne sont pas encore dans le jeu (jeu.ts), les fait passer par le cerveau, et
 * les range pour l'étiquetage — les plus suspectes d'abord :
 *
 *   1. le client a touché « Autre chose » sur les tuiles : le cerveau (ou
 *      l'ancien aiguillage) s'était trompé de pistes ;
 *   2. le cerveau n'était pas sûr ;
 *   3. le reste.
 *
 *   npm run banc:recolter             → les 7 derniers jours
 *   npm run banc:recolter -- 30       → les 30 derniers jours
 *
 * Écrit scripts/banc-ia/resultats/a-etiqueter-<date>.md : on y corrige
 * l'intention, puis on ajoute les lignes à jeu.ts. Chaque erreur vue en
 * production devient ainsi un cas du banc, et ne revient plus.
 *
 * Lecture seule : ne modifie rien en base.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { JEU } from './jeu.js';

const { serviceClient } = await import('../../src/services/supabase.js');
const { comprendre } = await import('../../src/ai/decideur.js');
const { LIBELLES } = await import('../../src/ai/aiguillage.js');

const jours = Number(process.argv[2] ?? 7);
const depuis = new Date(Date.now() - jours * 86_400_000).toISOString();
const db = serviceClient();

const { data, error } = await db
  .from('messages')
  .select('conversation_id, role, content, created_at')
  .in('role', ['user', 'assistant'])
  .gte('created_at', depuis)
  .order('created_at', { ascending: true })
  .limit(5000);
if (error) throw error;

const lignes = (data ?? []) as Array<{ conversation_id: string; role: string; content: string | null; created_at: string }>;
const connues = new Set(JEU.map((c) => normaliser(c.texte)));
// Ce qui n'est pas une phrase du client : bulles techniques, photos, vocaux.
const technique = /^(📷|🎤|J'ai envoyé une photo|L'utilisateur a parlé|Action :)/;
// Les tuiles touchées : le libellé est enregistré comme bulle du client.
const tuiles = new Set([...Object.values(LIBELLES), 'Autre chose', 'Oui, annuler', 'Non, la garder'].map(normaliser));

interface Candidat { texte: string; avant: string | null; autreChose: boolean }
const candidats = new Map<string, Candidat>();
for (let i = 0; i < lignes.length; i++) {
  const m = lignes[i]!;
  const texte = (m.content ?? '').trim();
  if (m.role !== 'user' || !texte || technique.test(texte) || texte.length > 300) continue;
  if (connues.has(normaliser(texte)) || tuiles.has(normaliser(texte))) continue;
  const precedent = lignes.slice(0, i).reverse().find((l) => l.conversation_id === m.conversation_id);
  const avant = precedent?.role === 'assistant' ? precedent.content : null;
  const suivant = lignes.slice(i + 1).find((l) => l.conversation_id === m.conversation_id && l.role === 'user');
  const autreChose = suivant?.content?.trim() === 'Autre chose';
  const cle = normaliser(texte);
  const deja = candidats.get(cle);
  candidats.set(cle, { texte, avant: deja?.avant ?? avant, autreChose: autreChose || Boolean(deja?.autreChose) });
}

console.log(`${candidats.size} phrases nouvelles sur ${jours} jours. Passage par le cerveau…`);
const resultats: Array<Candidat & { intention: string | null; sur: boolean }> = [];
const file = [...candidats.values()];
await Promise.all(Array.from({ length: 5 }, async () => {
  for (let c = file.shift(); c; c = file.shift()) {
    const d = await comprendre(c.texte, { avant: c.avant });
    resultats.push({ ...c, intention: d.intention, sur: d.sur });
  }
}));

const rang = (r: (typeof resultats)[number]) => (r.autreChose ? 0 : !r.sur ? 1 : 2);
resultats.sort((a, b) => rang(a) - rang(b));

const echapper = (t: string) => t.replace(/'/g, "\\'");
const md = [
  `# Phrases à étiqueter — ${new Date().toISOString().slice(0, 10)} (${jours} jours)`,
  '',
  'Corriger l’intention si besoin, puis copier les lignes dans `jeu.ts`.',
  '« Autre chose » = le client a rejeté les tuiles proposées ; « pas sûr » = le cerveau hésitait.',
  '',
  '```ts',
  ...resultats.map((r) => {
    const drapeau = r.autreChose ? ' // ⚠ Autre chose' : !r.sur ? ' // pas sûr' : '';
    const ctx = r.avant ? `, { contexte: true, avant: '${echapper(r.avant.replace(/\s+/g, ' ').slice(0, 160))}' }` : '';
    return `  r('${echapper(r.texte)}', '${r.intention ?? '?'}'${ctx}),${drapeau}`;
  }),
  '```',
].join('\n');

mkdirSync('scripts/banc-ia/resultats', { recursive: true });
const fichier = `scripts/banc-ia/resultats/a-etiqueter-${new Date().toISOString().slice(0, 10)}.md`;
writeFileSync(fichier, md);
console.log(`${resultats.filter((r) => r.autreChose).length} « Autre chose », ${resultats.filter((r) => !r.sur).length} pas sûr.`);
console.log(`→ ${fichier}`);

function normaliser(t: string): string {
  return t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();
}
