/**
 * Le banc IA : chaque candidat face au MÊME jeu de vraies phrases (jeu.ts).
 *
 *   npm run banc:ia                         → tous les candidats
 *   npm run banc:ia -- actuel gemini        → seulement ceux-là
 *
 * Mesure, pour chaque candidat :
 *   - la justesse (phrases qui se comprennent seules, puis les pièges) ;
 *   - les ACTIONS COÛTEUSES DÉCLENCHÉES À TORT (livreur, colis, annulation,
 *     recommande) — le chiffre qui compte : il doit être nul ;
 *   - la vitesse (médiane et 95e centile), mesurée depuis cette machine.
 *
 * « actuel » reproduit la production : l'aiguillage (classifieur local puis
 * Jev), les détecteurs à mots, et Gemini seulement quand l'aiguillage passe
 * la main. Les autres candidats sont interrogés avec UNE MÊME consigne : la
 * comparaison est juste.
 *
 * Lecture seule : ne touche ni à la base ni aux commandes.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { COUTEUSES, JEU, type Cas } from './jeu.js';
import type { Intention } from '../../src/ai/jev.js';

// La production tourne avec le classifieur local et l'aiguillage Jev.
process.env.CLASSIFIEUR_LOCAL = '1';
process.env.JEV_AIGUILLAGE = '1';

const { env } = await import('../../src/config/env.js');
const { INTENTIONS, classerIntention } = await import('../../src/ai/jev.js');
const { aiguiller } = await import('../../src/ai/cascade.js');
const { chargerClassifieur, classerLocalement } = await import('../../src/ai/classifieur.js');
const { demandeUnColis, demandeUnLivreur } = await import('../../src/ai/intents.js');
const { comprendre, essaiGemini, COUTEUSES: COUTEUSES_CERVEAU } = await import('../../src/ai/decideur.js');
type Reflexion = import('../../src/ai/decideur.js').Reflexion;

type Prediction = Intention | 'tuiles' | null;
interface Resultat { cas: Cas; predit: Prediction; ms: number; erreur?: string; via?: string }

// ─────────────────────────────────────────────────────────────────────
// La consigne commune aux modèles de langage
// ─────────────────────────────────────────────────────────────────────

const CONSIGNE = [
  'Tu classes le message d’un client de Tovo, une application de livraison à Niamey (Niger) : repas, courses et colis.',
  'Réponds UNIQUEMENT en JSON : {"intention": "<clé>"}, avec une de ces clés :',
  ...Object.entries(INTENTIONS).map(([cle, def]) => `- ${cle} : ${def}`),
  'Le client peut écrire avec des fautes, en français parlé, ou en haoussa ou en zarma.',
].join('\n');

function lireIntention(texte: string): Intention | null {
  const brut = texte.match(/\{[\s\S]*\}/)?.[0];
  try {
    const v = brut ? (JSON.parse(brut) as { intention?: string }).intention : undefined;
    return v && v in INTENTIONS ? (v as Intention) : null;
  } catch {
    return null;
  }
}

async function chronometrer(f: () => Promise<{ predit: Prediction; erreur?: string; via?: string }>) {
  const debut = performance.now();
  try {
    const r = await f();
    return { ...r, ms: performance.now() - debut };
  } catch (cause) {
    return { predit: null, erreur: String(cause).slice(0, 160), ms: performance.now() - debut };
  }
}

// ─────────────────────────────────────────────────────────────────────
// Les candidats
// ─────────────────────────────────────────────────────────────────────

async function gemini(message: string, modele = env.GEMINI_MODEL, reflexion = 'low') {
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY! },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: CONSIGNE }] },
      contents: [{ role: 'user', parts: [{ text: message }] }],
      generationConfig: {
        maxOutputTokens: 256,
        responseMimeType: 'application/json',
        // Les modèles 2.5 comptent en budget, les 3.x en niveaux.
        thinkingConfig: /gemini-2\.5/.test(modele)
          ? { thinkingBudget: reflexion === 'low' ? 512 : 0 }
          : { thinkingLevel: reflexion },
      },
    }),
    signal: AbortSignal.timeout(20_000),
  });
  const corps = (await r.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>; error?: { message?: string } };
  if (!r.ok) return { predit: null, erreur: `${r.status} ${corps.error?.message ?? ''}` };
  const texte = corps.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
  return { predit: lireIntention(texte) };
}

async function openai(message: string, modele: string) {
  const raisonne = /^(gpt-5|o\d)/.test(modele);
  const r = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: JSON.stringify({
      model: modele,
      messages: [{ role: 'system', content: CONSIGNE }, { role: 'user', content: message }],
      response_format: { type: 'json_object' },
      // gpt-5 / 5.1 : « minimal » ; à partir de 5.2 : « none ».
      ...(raisonne
        ? { reasoning_effort: /^gpt-5(\.1)?(-|$)/.test(modele) ? 'minimal' : 'none' }
        : { temperature: 0 }),
    }),
    signal: AbortSignal.timeout(20_000),
  });
  const corps = (await r.json()) as { choices?: Array<{ message?: { content?: string } }>; error?: { message?: string } };
  if (!r.ok) return { predit: null, erreur: `${r.status} ${corps.error?.message ?? ''}` };
  return { predit: lireIntention(corps.choices?.[0]?.message?.content ?? '') };
}

async function openrouter(message: string, modele: string) {
  const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENROUTER_API_KEY}` },
    body: JSON.stringify({
      model: modele,
      messages: [{ role: 'system', content: CONSIGNE }, { role: 'user', content: message }],
      temperature: 0,
      max_tokens: 60,
      // DeepSeek V4.x : le mode « non-reasoning » (le plus rapide).
      ...(/deepseek/.test(modele) ? { reasoning: { enabled: false } } : {}),
    }),
    signal: AbortSignal.timeout(20_000),
  });
  const corps = (await r.json()) as { choices?: Array<{ message?: { content?: string } }>; error?: { message?: string } };
  if (!r.ok) return { predit: null, erreur: `${r.status} ${corps.error?.message ?? ''}` };
  return { predit: lireIntention(corps.choices?.[0]?.message?.content ?? '') };
}

/**
 * La production, telle quelle : aiguillage, puis détecteurs à mots, puis
 * Gemini seulement si personne n'a décidé.
 */
async function actuel(message: string) {
  const a = await aiguiller(message);
  if (a.route.type === 'intention') return { predit: a.route.intention, via: a.source };
  if (a.route.type === 'clarifier') return { predit: 'tuiles' as const, via: a.source };
  if (demandeUnLivreur(message)) return { predit: 'livreur' as Intention, via: 'mots' };
  if (demandeUnColis(message)) return { predit: 'colis' as Intention, via: 'mots' };
  const g = await gemini(message);
  return { ...g, via: 'gemini' };
}

type Candidat = (m: string, cas?: Cas) => Promise<{ predit: Prediction; erreur?: string; via?: string }>;

/**
 * Le cerveau tel qu'en production (src/ai/decideur.ts) : sa consigne, sa
 * relance, ses secours, et le dernier message de Tovo quand il y en a un.
 * « Pas sûr » sur une action coûteuse → des tuiles, comme dans la route.
 */
async function cerveau(message: string, cas?: Cas, seul?: [string, Reflexion]) {
  const d = await comprendre(message, { avant: cas?.avant ?? null },
    seul ? { essais: [[seul[0], essaiGemini(seul[0], seul[1])]], delaiMaxMs: 20_000 } : {});
  if (!d.intention) return { predit: null, erreur: d.erreurs.join(' ; ') || 'aucune décision' };
  const predit: Prediction = !d.sur && COUTEUSES_CERVEAU.has(d.intention) ? 'tuiles' : d.intention;
  return { predit, via: `${d.modele}${d.relance ? ' (relance)' : ''}` };
}

/**
 * Hybride : le classifieur local (~20 ms) tranche seul quand il est sûr ET
 * que la route ne coûte rien ; tout le reste passe par le cerveau.
 */
async function hybride(message: string, cas?: Cas) {
  const local = cas?.avant ? null : await classerLocalement(message);
  if (local?.choix && local.confiance >= env.CLASSIFIEUR_SEUIL && !COUTEUSES_CERVEAU.has(local.choix)) {
    return { predit: local.choix as Prediction, via: 'local' };
  }
  return cerveau(message, cas);
}

/**
 * Un candidat par son nom : « gemini:<modèle>[:minimal] », « openai:<modèle> »,
 * « openrouter:<modèle> » — ou un des raccourcis ci-dessous.
 */
function candidat(nom: string): Candidat | undefined {
  if (CANDIDATS[nom]) return CANDIDATS[nom];
  const [fournisseur, ...reste] = nom.split(':');
  // « cerveau:<modèle>:<réflexion> » : la consigne du cerveau, UN modèle, sans relance.
  if (fournisseur === 'cerveau') return (m, cas) => cerveau(m, cas, [reste[0]!, (reste[1] ?? 'low') as Reflexion]);
  if (fournisseur === 'gemini') {
    const niveau = reste[1] ?? 'low';
    return (m) => gemini(m, reste[0], niveau);
  }
  if (fournisseur === 'openai') return (m) => openai(m, reste.join(':'));
  if (fournisseur === 'openrouter') return (m) => openrouter(m, reste.join(':'));
  return undefined;
}

const CANDIDATS: Record<string, Candidat> = {
  actuel,
  cerveau,
  hybride,
  jev: async (m) => {
    const d = await classerIntention(m, { cle: env.OPENROUTER_API_KEY!, modele: env.JEV_MODEL, delaiMs: 15_000 });
    return { predit: d.choix, ...(d.erreur ? { erreur: d.erreur } : {}) };
  },
  gemini: (m) => gemini(m),
  'gpt-5-mini': (m) => openai(m, 'gpt-5-mini'),
  'gpt-4.1-mini': (m) => openai(m, 'gpt-4.1-mini'),
  'claude-haiku-4.5': (m) => openrouter(m, 'anthropic/claude-haiku-4.5'),
};

// ─────────────────────────────────────────────────────────────────────
// Passage du jeu et rapport
// ─────────────────────────────────────────────────────────────────────

async function passer(nom: string, f: Candidat) {
  const resultats: Resultat[] = [];
  const file = [...JEU];
  // Quelques requêtes à la fois : assez pour aller vite, pas assez pour
  // être freiné par les limites des fournisseurs. Claude via un compte
  // OpenRouter récent : 20 requêtes par minute, une à la fois, espacées.
  const lent = /anthropic|claude/.test(nom);
  await Promise.all(Array.from({ length: lent ? 1 : 5 }, async () => {
    for (let cas = file.shift(); cas; cas = file.shift()) {
      const debut = Date.now();
      resultats.push({ cas, ...(await chronometrer(() => f(cas.texte, cas))) });
      if (lent) await new Promise((r) => setTimeout(r, Math.max(0, 3100 - (Date.now() - debut))));
    }
  }));
  return { nom, resultats };
}

const pct = (n: number, d: number) => (d === 0 ? '—' : `${Math.round((100 * n) / d)} %`);
const centile = (v: number[], p: number) => {
  const t = [...v].sort((a, b) => a - b);
  return t.length ? Math.round(t[Math.min(t.length - 1, Math.floor(p * t.length))]!) : 0;
};

function bilan({ nom, resultats }: { nom: string; resultats: Resultat[] }) {
  const seuls = resultats.filter((r) => !r.cas.contexte);
  const reels = seuls.filter((r) => r.cas.source === 'reel');
  const pieges = seuls.filter((r) => r.cas.source === 'piege');
  const juste = (r: Resultat) => r.predit === r.cas.attendu;
  // Livreur et colis déclenchent la MÊME course : confondre les deux n'est
  // pas une erreur coûteuse. Les phrases à contexte sont comptées à part.
  const course = (i: Prediction) => (i === 'livreur' || i === 'colis' ? 'course' : i);
  const aTort = seuls.filter((r) => r.predit && r.predit !== 'tuiles' && COUTEUSES.has(r.predit as Intention)
    && course(r.predit) !== course(r.cas.attendu));
  const tuiles = resultats.filter((r) => r.predit === 'tuiles');
  const avecAvant = resultats.filter((r) => r.cas.avant);
  const erreurs = resultats.filter((r) => r.erreur);
  const ms = resultats.filter((r) => !r.erreur).map((r) => r.ms);
  return {
    nom,
    justesse: pct(seuls.filter(juste).length, seuls.length),
    reels: pct(reels.filter(juste).length, reels.length),
    pieges: pct(pieges.filter(juste).length, pieges.length),
    aTort,
    tuiles: tuiles.length,
    contexte: `${avecAvant.filter(juste).length}/${avecAvant.length}`,
    erreurs,
    p50: centile(ms, 0.5),
    p95: centile(ms, 0.95),
  };
}

// Le classifieur local se charge en arrière-plan, comme au démarrage du
// serveur : on attend qu'il soit prêt avant de mesurer « actuel ».
const demandes = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const choisis = demandes.length === 0 ? Object.keys(CANDIDATS) : demandes.filter((n) => candidat(n));
if (choisis.includes('actuel') || choisis.includes('hybride')) {
  chargerClassifieur((m) => console.log('  ' + m));
  for (let i = 0; i < 120 && !(await classerLocalement('bonjour')); i++) await new Promise((r) => setTimeout(r, 500));
}

console.log(`\nJeu : ${JEU.length} phrases (${JEU.filter((c) => c.source === 'reel').length} réelles, ${JEU.filter((c) => c.source === 'piege').length} pièges, ${JEU.filter((c) => c.contexte).length} qui demandent le contexte)\n`);
const tous = [];
for (const nom of choisis) {
  process.stdout.write(`… ${nom}\n`);
  tous.push(await passer(nom, candidat(nom)!));
}

console.log('\n| Candidat | Justesse | Réels | Pièges | Actions coûteuses à tort | Tuiles | Contexte | Médiane | 95 % | Erreurs |');
console.log('|---|---|---|---|---|---|---|---|---|---|');
const bilans = tous.map(bilan);
for (const b of bilans) {
  console.log(`| ${b.nom} | ${b.justesse} | ${b.reels} | ${b.pieges} | **${b.aTort.length}** | ${b.tuiles} | ${b.contexte} | ${b.p50} ms | ${b.p95} ms | ${b.erreurs.length} |`);
}
for (const b of bilans) {
  if (b.aTort.length) {
    console.log(`\n${b.nom} — actions coûteuses à tort :`);
    for (const r of b.aTort) console.log(`   « ${r.cas.texte} » → ${r.predit}${r.via ? ` (${r.via})` : ''}, attendu ${r.cas.attendu}`);
  }
  // --detail : toutes les phrases ratées, pas seulement les coûteuses.
  if (process.argv.includes('--detail')) {
    const rates = tous.find((t) => t.nom === b.nom)!.resultats
      .filter((r) => r.predit !== r.cas.attendu && !r.erreur);
    console.log(`
${b.nom} — phrases ratées (${rates.length}) :`);
    for (const r of rates) console.log(`   « ${r.cas.texte} » → ${r.predit}${r.via ? ` (${r.via})` : ''}, attendu ${r.cas.attendu}${r.cas.contexte ? ' [contexte]' : ''}`);
  }
  if (b.erreurs.length) console.log(`\n${b.nom} — erreurs (${b.erreurs.length}) : ${b.erreurs[0]!.erreur}`);
}

mkdirSync('scripts/banc-ia/resultats', { recursive: true });
const fichier = `scripts/banc-ia/resultats/${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.json`;
writeFileSync(fichier, JSON.stringify(tous.map(({ nom, resultats }) => ({
  nom,
  resultats: resultats.map((r) => ({ texte: r.cas.texte, attendu: r.cas.attendu, predit: r.predit, ms: Math.round(r.ms), via: r.via, erreur: r.erreur })),
})), null, 1));
console.log(`\nDétail : ${fichier}`);
