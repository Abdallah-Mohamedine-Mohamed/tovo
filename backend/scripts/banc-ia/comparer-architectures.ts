/**
 * Faut-il laisser l'assistant (Gemini 3.8 Flash) tout faire, ou garder
 * « cerveau + chemins rapides + rédacteur » ? (02/10)
 *
 *   npx tsx --env-file=.env scripts/banc-ia/comparer-architectures.ts
 *   … -- --contre <résultat.json>   → la version ACTUELLE contre les réponses
 *                                     « actuel » enregistrées (avant / après)
 *
 * Les MÊMES phrases passent dans les deux organisations ; un juge (Gemini Pro)
 * compare les réponses À L'AVEUGLE (ordre tiré au hasard) : répond-elle à ce
 * que le client a dit, est-elle juste, invente-t-elle ? On mesure aussi le
 * temps et les jetons.
 *
 * Sans effet réel : aucune phrase qui commande, annule, signale ou touche au
 * panier ; chaque phrase dans sa propre conversation de test, supprimée après.
 */
import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { JEU, type Cas } from '../../src/ai/banc/jeu.js';
import { orchestrate } from '../../src/ai/orchestrator.js';
import { comprendre } from '../../src/ai/decideur.js';
import { serviceClient } from '../../src/services/supabase.js';
import type { Component } from '../../src/components/builders.js';

const db = serviceClient();
const POSITION = { lat: 13.52, lng: 2.11 };
const JUGE = 'gemini-3.1-pro-preview';
const SURES = new Set(['recherche', 'envie', 'boutique', 'social', 'question', 'suivi']);

// Les phrases de valeur : celles des captures du 02/10, puis les pièges,
// celles qui dépendent du message précédent, et quelques vraies phrases.
const CAPTURES: Array<{ texte: string; avant?: string }> = [
  { texte: 'Je voudrais bien manger des merguez' },
  { texte: 'Haddad Khalil' },
  { texte: 'Marina market' },
  { texte: 'Tu es sourd ?' },
  { texte: 'Je cherche de la pommade Nivea' },
  { texte: 'Quels sont tous les commerces hors de Tovo actuellement ?' },
  { texte: 'Je demande les boutiques qui ne sont pas sur Tovo' },
  { texte: 'Je veux commander de la viande chez Tchos' },
];
const sures = JEU.filter((c) => SURES.has(c.attendu));
const pieges = sures.filter((c) => c.source === 'piege').slice(0, 12);
const contexte = sures.filter((c) => c.avant).slice(0, 4);
const reels = sures.filter((c) => c.source === 'reel' && !c.avant).filter((_, i) => i % 15 === 0).slice(0, 6);
const PHRASES: Array<{ texte: string; avant?: string | undefined }> = [
  ...CAPTURES, ...[...pieges, ...contexte, ...reels].map((c: Cas) => ({ texte: c.texte, avant: c.avant })),
];

const { data: compte } = await db.from('conversations').select('user_id').order('created_at', { ascending: false }).limit(1).single();
const userId = compte!.user_id as string;

/** Ce que voit le client, en bref : le type de chaque carte et ses premiers éléments. */
function cartes(composants: Component[]): string {
  return composants.map((c) => {
    const d = c.data as Record<string, unknown>;
    const items = Array.isArray(d.items) ? (d.items as Array<Record<string, unknown>>) : [];
    const noms = items.slice(0, 4).map((i) => i.name ?? i.nom ?? i.label).filter(Boolean).join(' ; ');
    return `${c.type}${d.name ? ` « ${d.name} »` : ''}${noms ? ` [${noms}${items.length > 4 ? ` … ${items.length} en tout` : ''}]` : ''}`;
  }).join(' | ') || 'aucune carte';
}

async function passer(phrase: { texte: string; avant?: string | undefined }, mode: 'actuel' | 'assistant') {
  const { data: conv } = await db.from('conversations').insert({ user_id: userId }).select('id').single();
  const conversationId = conv!.id as string;
  try {
    if (phrase.avant) {
      await db.from('messages').insert({ conversation_id: conversationId, role: 'assistant', content: phrase.avant });
    }
    const debut = Date.now();
    // Comme la route : l'intention ET le produit compris par le cerveau.
    const d = mode === 'actuel' ? await comprendre(phrase.texte, { avant: phrase.avant ?? null }) : null;
    const intention = d ? d.intention ?? undefined : 'modele' as const;
    const r = await orchestrate({
      db, userId, conversationId, clientMessageId: randomUUID(), message: phrase.texte, position: POSITION, intention,
      ...(d?.produit ? { requete: d.produit } : {}),
    });
    return { texte: r.content, cartes: cartes(r.components), ms: Date.now() - debut, jetons: r.usage.input + r.usage.output, cycles: r.usage.cycles };
  } catch (e) {
    return { texte: `ERREUR : ${(e as Error).message.slice(0, 120)}`, cartes: '', ms: 0, jetons: 0, cycles: 0 };
  } finally {
    await db.from('messages').delete().eq('conversation_id', conversationId);
    await db.from('conversations').delete().eq('id', conversationId);
  }
}

type Verdict = { meilleure: 'A' | 'B' | 'egal'; noteA: number; noteB: number; inventionA: boolean; inventionB: boolean; raison: string };

async function juger(phrase: { texte: string; avant?: string | undefined }, a: { texte: string; cartes: string }, b: { texte: string; cartes: string }): Promise<Verdict | null> {
  const consigne = [
    'Tu évalues deux réponses de Tovo, une application de livraison à Niamey (repas, courses, colis), au même message d’un client.',
    'Sous le texte, l’application affiche des cartes (produits, boutiques, commerces hors Tovo avec boutons livreur / appel).',
    'Critères, dans l’ordre : 1) répond-elle à ce que le client a VRAIMENT dit ; 2) est-ce juste et utile (bonnes cartes) ;',
    '3) invente-t-elle un fait (prix, produit, boutique, promesse) qu’elle ne peut pas savoir ; 4) français naturel et bref.',
    'Note chacune de 1 à 5. Réponds en JSON : {"meilleure":"A"|"B"|"egal","noteA":n,"noteB":n,"inventionA":bool,"inventionB":bool,"raison":"une phrase"}.',
  ].join('\n');
  const entree = JSON.stringify({
    ...(phrase.avant ? { dernier_message_de_tovo: phrase.avant } : {}),
    message_du_client: phrase.texte,
    reponse_A: { texte: a.texte, cartes: a.cartes },
    reponse_B: { texte: b.texte, cartes: b.cartes },
  });
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${JUGE}:generateContent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY! },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: consigne }] },
      contents: [{ role: 'user', parts: [{ text: entree }] }],
      generationConfig: { temperature: 0, responseMimeType: 'application/json', maxOutputTokens: 2048, thinkingConfig: { thinkingLevel: 'low' } },
    }),
  }).catch(() => null);
  if (!r?.ok) return null;
  const corps = (await r.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
  const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
  try { return JSON.parse(texte) as Verdict; } catch { return null; }
}

// Avant / après : les réponses « actuel » d'un passage précédent tiennent le
// rôle de l'« assistant » (colonne B), sans être rejouées.
const iContre = process.argv.indexOf('--contre');
const avant = iContre > 0
  ? new Map((JSON.parse(readFileSync(process.argv[iContre + 1]!, 'utf8')) as Array<{ phrase: string; actuel: { texte: string; cartes: string; ms: number; jetons: number; cycles: number } }>)
    .map((x) => [x.phrase, x.actuel]))
  : null;

const resultats: Array<Record<string, unknown>> = [];
const file = avant ? PHRASES.filter((p) => avant.has(p.texte)) : [...PHRASES];
await Promise.all(Array.from({ length: 3 }, async () => {
  for (let p = file.shift(); p; p = file.shift()) {
    const actuel = await passer(p, 'actuel');
    const assistant = avant ? avant.get(p.texte)! : await passer(p, 'assistant');
    const actuelEnA = Math.random() < 0.5;
    const v = await juger(p, actuelEnA ? actuel : assistant, actuelEnA ? assistant : actuel);
    const gagnant = !v ? null : v.meilleure === 'egal' ? 'egal' : (v.meilleure === 'A') === actuelEnA ? 'actuel' : 'assistant';
    resultats.push({
      phrase: p.texte, avant: p.avant ?? null, actuel, assistant, gagnant,
      note_actuel: v ? (actuelEnA ? v.noteA : v.noteB) : null,
      note_assistant: v ? (actuelEnA ? v.noteB : v.noteA) : null,
      invention_actuel: v ? (actuelEnA ? v.inventionA : v.inventionB) : null,
      invention_assistant: v ? (actuelEnA ? v.inventionB : v.inventionA) : null,
      raison: v?.raison ?? null,
    });
    process.stdout.write('.');
  }
}));

const n = resultats.length;
const moy = (cle: string) => (resultats.reduce((s, r) => s + Number(r[cle] ?? 0), 0) / resultats.filter((r) => r[cle] !== null).length).toFixed(2);
const mediane = (mode: 'actuel' | 'assistant') => {
  const t = resultats.map((r) => (r[mode] as { ms: number }).ms).sort((a, b) => a - b);
  return t[Math.floor(t.length / 2)];
};
const p95 = (mode: 'actuel' | 'assistant') => {
  const t = resultats.map((r) => (r[mode] as { ms: number }).ms).sort((a, b) => a - b);
  return t[Math.min(t.length - 1, Math.floor(0.95 * t.length))];
};
const jetons = (mode: 'actuel' | 'assistant') => Math.round(resultats.reduce((s, r) => s + (r[mode] as { jetons: number }).jetons, 0) / n);
const compter = (g: string) => resultats.filter((r) => r.gagnant === g).length;

console.log(`\n\n${n} phrases`);
const [nomA, nomB] = avant ? ['après', 'avant'] : ['actuel', 'assistant seul'];
console.log(`Gagnant : ${nomA} ${compter('actuel')}, ${nomB} ${compter('assistant')}, égalité ${compter('egal')}`);
console.log(`Note moyenne (/5) : actuel ${moy('note_actuel')}, assistant ${moy('note_assistant')}`);
console.log(`Inventions : actuel ${resultats.filter((r) => r.invention_actuel).length}, assistant ${resultats.filter((r) => r.invention_assistant).length}`);
console.log(`Temps médian : actuel ${mediane('actuel')} ms, assistant ${mediane('assistant')} ms ; 95 % : ${p95('actuel')} / ${p95('assistant')} ms`);
console.log(`Jetons de l'assistant par message (hors rédacteur et cerveau) : actuel ${jetons('actuel')}, assistant ${jetons('assistant')}`);
mkdirSync('scripts/banc-ia/resultats', { recursive: true });
const fichier = `scripts/banc-ia/resultats/architectures-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.json`;
writeFileSync(fichier, JSON.stringify(resultats, null, 1));
console.log(`Détail : ${fichier}`);
