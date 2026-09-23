/**
 * Distillation : Jev (précis mais lent et distant) enseigne au classifieur
 * local (rapide mais moins fin).
 *
 *   npm run classifieur:distiller
 *
 * 1. De nouvelles phrases SANS étiquette :
 *    - modèles construits sur le vrai catalogue (« un coca », « chez
 *      O'Takoss », « vous avez du riz ? ») : les messages les plus courants ;
 *    - phrases variées générées par Gemini, dans tous les registres.
 * 2. Jev les étiquette ; on ne garde que ses décisions sûres (≥ 0,9).
 * 3. Jev relit aussi le corpus d'apprentissage : une phrase qu'il classe
 *    AILLEURS avec assurance est ambiguë ou mal étiquetée — écartée.
 *
 * Les phrases de TEST du corpus (1 sur 5 par intention, comme dans banc.ts)
 * ne sont jamais ni relues ni reprises : la mesure reste honnête.
 *
 * Écrit scripts/corpus/distille.json. Lecture seule sur la base.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { classerIntention, INTENTIONS, type Intention } from '../../src/ai/jev.js';
import { llmClient } from '../../src/ai/llmClient.js';
import { normaliserIntention } from '../../src/ai/intents.js';

const CLE = process.env.OPENROUTER_API_KEY;
if (!CLE) throw new Error('OPENROUTER_API_KEY absente.');
const SUR = 0.9;
const PARALLELE = 8;

interface Ligne { texte: string; intention: Intention; registre: string }
const corpus = JSON.parse(readFileSync('scripts/corpus/corpus.json', 'utf8')) as Ligne[];

// Même répartition que banc.ts : ces phrases de test restent intactes.
const vus = new Map<string, number>();
const test = new Set<string>();
const apprentissage: Ligne[] = [];
for (const l of corpus) {
  const n = (vus.get(l.intention) ?? 0) + 1;
  vus.set(l.intention, n);
  if (n % 5 === 0) test.add(normaliserIntention(l.texte)); else apprentissage.push(l);
}

// --- 1a. Modèles sur le vrai catalogue ------------------------------------
let graine = 424242;
const hasard = () => ((graine = (graine * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const tirer = <T>(t: T[], n: number) => t.map((x) => [hasard(), x] as const).sort((a, b) => a[0] - b[0]).slice(0, n).map(([, x]) => x);

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
const [p, m] = await Promise.all([
  db.from('products').select('name').eq('is_available', true).limit(1000),
  db.from('merchants').select('name').eq('is_approved', true),
]);
const court = (nom: string) => nom.replace(/\([^)]*\)/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
const produits = [...new Set((p.data ?? []).map((x) => court(x.name as string)))].filter((x) => x.length >= 3);
const boutiques = [...new Set((m.data ?? []).map((x) => court(x.name as string)))].filter((x) => x.length >= 3);

const formesProduit = ['{p}', 'un {p}', 'du {p}', 'je veux {p}', '{p} stp', 'vous avez {p} ?', 'il me faut {p}', 'je cherche {p}', '2 {p}', 'jveu {p}'];
const formesBoutique = ['{m}', 'chez {m}', 'la carte de {m}', '{m} est ouvert ?', 'montre moi {m}', 'qu’est-ce qu’il y a chez {m}'];
const modeles = [
  ...tirer(produits, 500).map((x) => formesProduit[Math.floor(hasard() * formesProduit.length)]!.replace('{p}', x)),
  ...tirer(boutiques, 80).flatMap((x) => tirer(formesBoutique, 2).map((f) => f.replace('{m}', x))),
];

// --- 1b. Phrases variées par Gemini, sans étiquette imposée ----------------
const client = llmClient();
const genere: string[] = [];
if (client) {
  const themes = [
    'demander un produit ou un plat précis', 'exprimer une envie vague de manger ou de faire des courses',
    'demander un livreur ou un coursier', 'envoyer un colis ou un document', 'suivre sa commande en cours, s’impatienter',
    'annuler une commande', 'refaire une commande passée', 'choisir parmi des produits affichés à l’écran',
    'saluer, remercier, se plaindre, bavarder', 'demander une boutique ou un restaurant précis',
  ];
  await Promise.all(themes.map(async (theme) => {
    try {
      const r = await client.generate({
        system: 'Tu produis uniquement le JSON demandé.',
        history: [{ role: 'user', content:
          `Écris 60 messages COURTS et DIFFÉRENTS qu’un client de Tovo (livraison à Niamey, Niger) enverrait pour : ${theme}. ` +
          'Mélange les registres : français correct, SMS (jveu, stp, bjr), fautes de frappe, vocal transcrit sans ponctuation, français de Niamey. ' +
          'Beaucoup de messages de 1 à 6 mots. Pas de numérotation.' }],
        tools: [], cachePrompt: false,
        responseSchema: { type: 'OBJECT', properties: { messages: { type: 'ARRAY', items: { type: 'STRING' } } }, required: ['messages'] },
      });
      genere.push(...((JSON.parse(r.text) as { messages: string[] }).messages ?? []).filter((x) => typeof x === 'string'));
    } catch { /* thème sauté */ }
  }));
}

// Jamais une phrase de test, jamais un doublon.
const dejaVu = new Set([...test, ...apprentissage.map((l) => normaliserIntention(l.texte))]);
const nouvelles = [...new Set([...modeles, ...genere].map((x) => x.trim()).filter(Boolean))]
  .filter((x) => { const k = normaliserIntention(x); if (dejaVu.has(k)) return false; dejaVu.add(k); return true; });
console.log(`${modeles.length} phrases-modèles, ${genere.length} générées → ${nouvelles.length} nouvelles ; ${apprentissage.length} phrases du corpus à relire.`);

// --- 2 et 3. Jev étiquette et relit ----------------------------------------
async function enParallele<T, R>(t: T[], n: number, f: (e: T) => Promise<R>): Promise<R[]> {
  const s: R[] = new Array(t.length); let k = 0; let faits = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (k < t.length) { const i = k++; s[i] = await f(t[i]!); if (++faits % 100 === 0) process.stdout.write(`\r${faits}/${t.length}`); }
  }));
  process.stdout.write('\n');
  return s;
}
const aEtiqueter = [...nouvelles, ...apprentissage.map((l) => l.texte)];
const decisions = await enParallele(aEtiqueter, PARALLELE, (texte) => classerIntention(texte, { cle: CLE, modele: 'typesafe/jev-1.13', delaiMs: 20_000 }));

const distille: Array<{ texte: string; intention: Intention; source: string }> = [];
let gardees = 0, incertaines = 0, echecs = 0, contredites = 0;
nouvelles.forEach((texte, i) => {
  const d = decisions[i]!;
  if (d.erreur || !d.choix) { echecs++; return; }
  if (d.confiance >= SUR) { distille.push({ texte, intention: d.choix, source: 'jev' }); gardees++; } else incertaines++;
});
apprentissage.forEach((l, j) => {
  const d = decisions[nouvelles.length + j]!;
  if (!d.erreur && d.choix && d.choix !== l.intention && d.confiance >= SUR) { contredites++; return; }
  distille.push({ texte: l.texte, intention: l.intention, source: 'corpus' });
});

writeFileSync('scripts/corpus/distille.json', JSON.stringify(distille, null, 1));
const parIntention = Object.fromEntries((Object.keys(INTENTIONS) as Intention[]).map((i) => [i, distille.filter((x) => x.intention === i).length]));
console.log(`Nouvelles gardées (Jev ≥ ${SUR}) : ${gardees} · incertaines écartées : ${incertaines} · échecs Jev : ${echecs}`);
console.log(`Corpus : ${contredites} phrases contredites par Jev avec assurance, écartées.`);
console.log(`scripts/corpus/distille.json : ${distille.length} phrases`, parIntention);
