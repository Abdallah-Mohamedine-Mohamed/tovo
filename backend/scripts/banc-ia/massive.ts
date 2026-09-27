/**
 * Des phrases HUMAINES publiques pour la banque : MASSIVE (Amazon Science,
 * licence CC BY 4.0), partie française.
 *
 *   npm run banc:massive -- <chemin de fr-FR.jsonl>            → juge et garde le résultat
 *   npm run banc:massive -- --inserer                          → met en base ce qui a été jugé
 *
 * MASSIVE vient d'assistants vocaux (musique, agenda, météo…) : on garde ce
 * qui touche au métier (plats à emporter, lieux, taxi, listes de courses,
 * salutations) et un échantillon du reste, précieux pour apprendre ce qui
 * n'est PAS une commande. Chaque phrase est étiquetée à l'aveugle par deux
 * modèles forts ; seul leur accord entre dans la banque (origine 'public').
 *
 * Attribution : « MASSIVE: A 1M-Example Multilingual Natural Language
 * Understanding Dataset », FitzGerald et al., 2022, Amazon Science.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const { serviceClient } = await import('../../src/services/supabase.js');
const { ecrivain, juge } = await import('../../src/ai/banc/modelesForts.js');
const { cleDe, etiqueterALAveugle, memeSens } = await import('../../src/ai/banc/boucle.js');
type Etiquette = import('../../src/ai/banc/guide.js').Etiquette;

const RESULTAT = 'scripts/banc-ia/resultats/massive-juge.json';
const argv = process.argv.slice(2);

if (argv.includes('--inserer')) {
  const { gardees } = JSON.parse(readFileSync(RESULTAT, 'utf8')) as { gardees: Array<{ texte: string; attendu: string; intention_massive: string }> };
  const lignes = gardees.map((g) => ({
    texte: g.texte, avant: null, attendu: g.attendu, origine: 'public', statut: 'valide',
    etiqueteur: g.attendu, juge: g.attendu, cerveau: null,
    note: `MASSIVE (Amazon, CC BY 4.0) — intention d'origine : ${g.intention_massive}`, cle: cleDe(g.texte),
  }));
  const db = serviceClient();
  for (let i = 0; i < lignes.length; i += 500) {
    const { error } = await db.from('banc_cas').upsert(lignes.slice(i, i + 500), { onConflict: 'cle', ignoreDuplicates: true });
    if (error) throw new Error(`${error.message} — la migration 0068 est-elle appliquée ?`);
  }
  console.log(`${lignes.length} phrases MASSIVE mises en base`);
  process.exit(0);
}

const chemin = argv.find((a) => !a.startsWith('--'));
if (!chemin || !existsSync(chemin)) throw new Error('chemin de fr-FR.jsonl manquant');
const toutes = readFileSync(chemin, 'utf8').trim().split('\n').map((l) => JSON.parse(l) as { utt: string; intent: string });

// Ce qu'on garde, par intention MASSIVE.
const QUOTAS: Record<string, number> = {
  takeaway_order: 999, takeaway_query: 999, recommendation_locations: 999, transport_taxi: 999,
  lists_createoradd: 120, lists_query: 40, cooking_recipe: 40, general_greet: 999, general_quirky: 90, general_joke: 30,
};
const HORS_SUJET_PAR_INTENTION = 8;
const melange = <T>(l: T[]) => [...l].sort(() => Math.random() - 0.5);
// « olly » : le mot d'éveil de l'assistant vocal d'origine.
const propre = (t: string) => t.replace(/\bolly\b[,]?\s*/gi, '').replace(/\s+/g, ' ').trim();

const vues = new Set<string>();
const choisies: Array<{ texte: string; intention_massive: string }> = [];
const parIntention = new Map<string, string[]>();
for (const l of toutes) parIntention.set(l.intent, [...(parIntention.get(l.intent) ?? []), l.utt]);
for (const [intention, phrases] of parIntention) {
  const quota = QUOTAS[intention] ?? HORS_SUJET_PAR_INTENTION;
  let n = 0;
  for (const brute of melange(phrases)) {
    const texte = propre(brute);
    const cle = cleDe(texte);
    if (texte.length < 3 || vues.has(cle)) continue;
    vues.add(cle);
    choisies.push({ texte, intention_massive: intention });
    if (++n >= quota) break;
  }
}
console.log(`${choisies.length} phrases choisies sur ${toutes.length}`);

async function etiqueter(modele: ReturnType<typeof juge>): Promise<Array<Etiquette | null>> {
  const paquets: (typeof choisies)[] = [];
  for (let i = 0; i < choisies.length; i += 40) paquets.push(choisies.slice(i, i + 40));
  const sorties: Array<Array<Etiquette | null>> = new Array(paquets.length);
  let suivant = 0;
  await Promise.all(Array.from({ length: 3 }, async () => {
    for (let i = suivant++; i < paquets.length; i = suivant++) {
      try {
        sorties[i] = await etiqueterALAveugle(modele, paquets[i]!);
      } catch (cause) {
        console.log(`panne ${modele.nom} : ${(cause as Error).message.slice(0, 100)}`);
        sorties[i] = paquets[i]!.map(() => null);
      }
    }
  }));
  return sorties.flat();
}

const [a, b] = await Promise.all([etiqueter(juge()), etiqueter(ecrivain())]);
const gardees: Array<{ texte: string; attendu: string; intention_massive: string }> = [];
const desaccords: Array<{ texte: string; gpt: string | null; gemini: string | null; intention_massive: string }> = [];
choisies.forEach((c, i) => {
  const x = a[i] ?? null;
  const y = b[i] ?? null;
  if (x && y && x !== 'ambigu' && memeSens(x, y)) gardees.push({ texte: c.texte, attendu: x, intention_massive: c.intention_massive });
  else desaccords.push({ texte: c.texte, gpt: x, gemini: y, intention_massive: c.intention_massive });
});
mkdirSync('scripts/banc-ia/resultats', { recursive: true });
writeFileSync(RESULTAT, JSON.stringify({ gardees, desaccords }, null, 1));
const compte: Record<string, number> = {};
for (const g of gardees) compte[g.attendu] = (compte[g.attendu] ?? 0) + 1;
console.log(`${gardees.length} gardées par accord des deux IA, ${desaccords.length} écartées`);
console.log('Par intention Tovo :', JSON.stringify(compte));
console.log(`Détail : ${RESULTAT} — puis npm run banc:massive -- --inserer (après la migration 0068)`);
