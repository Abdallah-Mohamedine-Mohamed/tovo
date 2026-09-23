/**
 * Générateur de corpus : des centaines de phrases de clients réalistes,
 * construites à partir du VRAI catalogue, pour mesurer les routeurs
 * d'intention (npm run banc:jev -- --corpus) sur autre chose que 61 phrases.
 *
 *   npm run corpus:generer            → ~1 500 phrases (25 par intention × registre)
 *   npm run corpus:generer -- 10      → 10 par case, pour un essai rapide
 *
 * Lecture seule sur la base (noms de boutiques, produits, catégories).
 * Écrit scripts/corpus/corpus.json et scripts/corpus/a-verifier.csv.
 *
 * LIMITE À GARDER EN TÊTE : les étiquettes viennent de la consigne donnée à
 * Gemini, pas d'un humain. Un échantillon doit être relu (a-verifier.csv),
 * et TOUT ce qui mêle zarma ou haoussa doit l'être par un locuteur natif.
 */
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { llmClient } from '../../src/ai/llmClient.js';
import { INTENTIONS, type Intention } from '../../src/ai/jev.js';
import { normaliserIntention } from '../../src/ai/intents.js';

const PAR_CASE = Number(process.argv[2] ?? 25);
const PARALLELE = 4;

const REGISTRES = {
  standard: 'Français correct, comme un client poli qui écrit posément.',
  sms: 'Style SMS : abréviations (jveu, stp, bjr, slt, cc, tkt, qd, pr), pas de majuscules ni d’accents, ponctuation absente.',
  fautes: 'Fautes de frappe et d’orthographe réalistes sur téléphone (lettres inversées, accents manquants, mots collés).',
  vocal: 'Message dicté puis transcrit : pas de ponctuation, hésitations (euh, genre, bon), phrases longues ou coupées.',
  niger: 'Français parlé à Niamey : tournures locales (« on est ensemble », « c’est comment », « il faut me… », « dèh », « wallahi »), familier.',
  piege: 'Phrases PIÈGES qui ressemblent à une AUTRE intention (mêmes mots-clés) mais appartiennent bien à celle-ci. Ex. pour « suivi » : « le livreur » sans en demander un.',
  local: 'Mélange de français avec des mots zarma ou haoussa courants à Niamey. N’invente pas de mots : si tu n’es pas sûr d’un mot local, reste en français familier.',
} as const;
type Registre = keyof typeof REGISTRES;

const client = llmClient();
if (!client) throw new Error('GEMINI_API_KEY absente : impossible de générer.');

// --- Le vrai catalogue, en lecture seule --------------------------------
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const [boutiques, produits, categories] = await Promise.all([
  db.from('merchants').select('name').eq('is_approved', true).limit(400),
  db.from('products').select('name').eq('is_available', true).limit(3000),
  db.from('categories').select('name'),
]);
for (const r of [boutiques, produits, categories]) if (r.error) throw r.error;
const noms = (r: { data: Array<{ name: string }> | null }) => [...new Set((r.data ?? []).map((x) => x.name.trim()).filter(Boolean))];
const NOMS_BOUTIQUES = noms(boutiques);
const NOMS_PRODUITS = noms(produits);
const NOMS_CATEGORIES = noms(categories);
console.log(`Catalogue : ${NOMS_BOUTIQUES.length} boutiques, ${NOMS_PRODUITS.length} produits, ${NOMS_CATEGORIES.length} catégories.`);

const tirer = <T>(liste: T[], n: number) => [...liste].sort(() => Math.random() - 0.5).slice(0, n);

// --- Génération ----------------------------------------------------------
interface Ligne { texte: string; intention: Intention; registre: Registre }

async function generer(intention: Intention, registre: Registre): Promise<Ligne[]> {
  const autres = Object.entries(INTENTIONS).filter(([k]) => k !== intention)
    .map(([k, v]) => `- ${k} : ${v}`).join('\n');
  const consigne = [
    'Tu fabriques des données de test pour Tovo, une application de livraison à Niamey (Niger) :',
    'repas, courses, colis. Les clients écrivent ou parlent à un assistant.',
    '',
    `Écris ${PAR_CASE} messages DIFFÉRENTS qu’un client pourrait envoyer, qui relèvent TOUS de cette intention :`,
    `« ${intention} » : ${INTENTIONS[intention]}`,
    '',
    `Registre imposé : ${REGISTRES[registre]}`,
    '',
    'Ils ne doivent relever d’AUCUNE de ces autres intentions :',
    autres,
    '',
    'Varie la longueur (de 1 mot à 2 phrases), le ton, la politesse. Pas de numérotation, pas de guillemets.',
    'Quand c’est naturel, utilise ces vrais noms :',
    `Produits : ${tirer(NOMS_PRODUITS, 15).join(' ; ')}`,
    `Boutiques : ${tirer(NOMS_BOUTIQUES, 8).join(' ; ')}`,
    `Catégories : ${tirer(NOMS_CATEGORIES, 6).join(' ; ')}`,
    'Pour « designe », le client vient de voir une liste de produits à l’écran.',
  ].join('\n');

  for (let essai = 0; essai < 2; essai++) {
    try {
      const reponse = await client!.generate({
        system: 'Tu produis uniquement le JSON demandé.',
        history: [{ role: 'user', content: consigne }],
        tools: [],
        cachePrompt: false,
        responseSchema: {
          type: 'OBJECT',
          properties: { phrases: { type: 'ARRAY', items: { type: 'STRING' } } },
          required: ['phrases'],
        },
      });
      const { phrases } = JSON.parse(reponse.text) as { phrases?: unknown };
      if (!Array.isArray(phrases)) throw new Error('forme inattendue');
      return phrases
        .filter((p): p is string => typeof p === 'string' && p.trim().length > 0 && p.length < 300)
        .map((texte) => ({ texte: texte.trim(), intention, registre }));
    } catch (cause) {
      if (essai === 1) console.log(`  ✗ ${intention}/${registre} : ${cause instanceof Error ? cause.message : cause}`);
    }
  }
  return [];
}

const cases = (Object.keys(INTENTIONS) as Intention[])
  .flatMap((i) => (Object.keys(REGISTRES) as Registre[]).map((r) => [i, r] as const));
const resultats: Ligne[][] = new Array(cases.length);
let suivant = 0;
let faites = 0;
await Promise.all(Array.from({ length: PARALLELE }, async () => {
  while (suivant < cases.length) {
    const k = suivant++;
    resultats[k] = await generer(...cases[k]!);
    process.stdout.write(`\r${++faites}/${cases.length} cases générées`);
  }
}));
console.log('');

// --- Dédoublonnage : une même phrase étiquetée deux fois est écartée ----
const parTexte = new Map<string, Ligne[]>();
for (const l of resultats.flat()) {
  const cle = normaliserIntention(l.texte);
  parTexte.set(cle, [...(parTexte.get(cle) ?? []), l]);
}
const corpus: Ligne[] = [];
let conflits = 0;
for (const lignes of parTexte.values()) {
  if (new Set(lignes.map((l) => l.intention)).size > 1) { conflits++; continue; }
  corpus.push(lignes[0]!);
}

writeFileSync('scripts/corpus/corpus.json', JSON.stringify(corpus, null, 1));

// Échantillon à relire : 10 % au hasard, plus TOUT le registre « local ».
const aRelire = corpus.filter((l) => l.registre === 'local' || Math.random() < 0.1);
const csv = ['texte;intention;registre;correct (o/n)']
  .concat(aRelire.map((l) => `"${l.texte.replace(/"/g, '""')}";${l.intention};${l.registre};`))
  .join('\n');
writeFileSync('scripts/corpus/a-verifier.csv', `﻿${csv}`);

const parIntention = Object.fromEntries((Object.keys(INTENTIONS) as Intention[])
  .map((i) => [i, corpus.filter((l) => l.intention === i).length]));
console.log(`Corpus : ${corpus.length} phrases uniques (${conflits} ambiguës écartées).`, parIntention);
console.log(`À relire : scripts/corpus/a-verifier.csv (${aRelire.length} lignes, dont tout le zarma/haoussa).`);
