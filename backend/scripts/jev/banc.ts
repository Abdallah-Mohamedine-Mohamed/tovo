/**
 * Banc d'essai des routeurs d'intention : qui comprend le mieux ce que veut
 * le client, AVANT l'appel coûteux à Gemini ?
 *
 *   npm run banc:jev
 *
 * Trois concurrents sur les mêmes phrases (scripts/jev/phrases.ts) :
 *   1. Détecteurs à mots — ce que le serveur fait aujourd'hui (intents.ts).
 *   2. Jev (TypeSafe via OpenRouter) — si OPENROUTER_API_KEY est présente.
 *   3. Plus proches voisins sur embeddings Gemini — si GEMINI_API_KEY est
 *      présente. Évalué en « laisser-un-dehors » : chaque phrase est classée
 *      d'après les AUTRES, jamais d'après elle-même.
 *
 * N'envoie que les phrases de test, jamais de donnée client. Ne touche ni à
 * la base ni à l'application.
 */
import {
  demandeDeCommandePassee,
  demandeGeneraleDeRepas,
  demandeOuverte,
  demandeUnColis,
  demandeUnLivreur,
  messageConversationnel,
  nomBoutiqueApresMarqueur,
  referenceAuxResultats,
  requeteProduitUtilisateur,
} from '../../src/ai/intents.js';
import { classerIntention } from '../../src/ai/jev.js';
import { embed } from '../../src/services/embeddings.js';
import { existsSync, readFileSync } from 'node:fs';
import { PHRASES, type Intention } from './phrases.js';

const CLE_JEV = process.env.OPENROUTER_API_KEY;
// Épinglé : jev-latest bougera à la prochaine version.
const MODELE = process.env.JEV_MODEL ?? 'typesafe/jev-1.13';
const SEUIL = Number(process.env.JEV_SEUIL ?? 0.8);
const PARALLELE = 8;

// `--corpus` : le grand corpus généré (scripts/corpus), sinon les 61 phrases.
const FICHIER_CORPUS = 'scripts/corpus/corpus.json';
const avecCorpus = process.argv.includes('--corpus');
if (avecCorpus && !existsSync(FICHIER_CORPUS)) throw new Error('Corpus absent : lancez npm run corpus:generer');
const JEU: Array<[string, Intention, string]> = avecCorpus
  ? (JSON.parse(readFileSync(FICHIER_CORPUS, 'utf8')) as Array<{ texte: string; intention: Intention; registre: string }>)
    .map((l) => [l.texte, l.intention, l.registre])
  : PHRASES.map(([texte, intention]) => [texte, intention, 'banc']);

type Verdict = Intention | 'modele';

interface Ligne {
  message: string;
  attendu: Intention;
  registre: string;
  choix: Verdict | null;
  confiance: number;
  ms: number;
  cout: number;
}

// ---------------------------------------------------------------------------
// 1. Nos détecteurs, dans l'ordre où le serveur les applique
// ---------------------------------------------------------------------------

/**
 * Ce que le serveur décide AUJOURD'HUI sans modèle. `modele` : aucune voie
 * rapide, Gemini tranche. La dernière étape reproduit `rechercheProduitRapide`
 * (orchestrator.ts), non exportée ; la garder alignée si elle change.
 */
function detecteurs(message: string): Verdict {
  if (demandeUnLivreur(message)) return 'livreur';
  if (demandeUnColis(message)) return 'colis';
  // Repérés, mais toujours confiés à Gemini (orchestrator.ts, versModele).
  if (referenceAuxResultats(message) || demandeDeCommandePassee(message)) return 'modele';
  // Ces deux-là n'ont pas de réponse propre : elles écartent seulement la
  // recherche rapide, et le message part chez Gemini.
  if (messageConversationnel(message)) return 'modele';
  // Seule voie rapide « envie » réelle : la porte Restaurants (chat.ts).
  if (demandeGeneraleDeRepas(message)) return 'envie';
  if (nomBoutiqueApresMarqueur(message)) return 'boutique';
  const requete = requeteProduitUtilisateur(message);
  if (requete && demandeOuverte(requete)) return 'modele';
  const exclus = /\b(merci|bonjour|salut|oui|non|annule|commande|livreur|colis|panier|option|options|deuxieme|premier)\b/i;
  if (requete && requete.split(/\s+/).length <= 6 && !exclus.test(message)) return 'recherche';
  return 'modele';
}

// ---------------------------------------------------------------------------
// 3. Plus proches voisins sur embeddings
// ---------------------------------------------------------------------------

const cosinus = (a: number[], b: number[]) => {
  let p = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { p += a[i]! * b[i]!; na += a[i]! ** 2; nb += b[i]! ** 2; }
  return p / Math.sqrt(na * nb);
};

/** Vote des k voisins, pondéré par la similarité ; confiance = part du vote. */
function voisins(i: number, vecteurs: number[][], k = 5): { choix: Intention; confiance: number } {
  const scores = vecteurs
    .map((v, j) => ({ j, s: j === i ? -Infinity : cosinus(vecteurs[i]!, v) }))
    .sort((a, b) => b.s - a.s)
    .slice(0, k);
  const votes = new Map<Intention, number>();
  for (const { j, s } of scores) votes.set(JEU[j]![1], (votes.get(JEU[j]![1]) ?? 0) + Math.max(s, 0));
  const total = [...votes.values()].reduce((a, b) => a + b, 0) || 1;
  const [choix, poids] = [...votes.entries()].sort((a, b) => b[1] - a[1])[0]!;
  return { choix, confiance: poids / total };
}

// ---------------------------------------------------------------------------

async function enParallele<T, R>(elements: T[], n: number, f: (e: T) => Promise<R>): Promise<R[]> {
  const sortie: R[] = new Array(elements.length);
  let suivant = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (suivant < elements.length) {
      const i = suivant++;
      sortie[i] = await f(elements[i]!);
    }
  }));
  return sortie;
}

const pct = (a: number, b: number) => (b === 0 ? '—' : `${Math.round((100 * a) / b)} %`);
const centile = (v: number[], p: number) => {
  const t = [...v].sort((a, b) => a - b);
  return t.length ? Math.round(t[Math.min(t.length - 1, Math.floor((p / 100) * t.length))]!) : 0;
};

// Un nom d'enseigne seul (« Otakoss ») est reconnu par la BASE en production
// (resolveCatalogueIntent) : on l'écarte de la mesure pour tous.
const baseTexte = new Map(JEU.map(([m]) => [m, detecteurs(m)]));
const ecarte = (message: string, attendu: Intention) =>
  attendu === 'boutique' && !nomBoutiqueApresMarqueur(message);

interface Bilan { nom: string; justesSansGemini: number; fausses: number; n: number; lignes: Ligne[] }

function bilan(nom: string, lignes: Ligne[], seuil: number | null): Bilan {
  const mesure = lignes.filter((l) => !ecarte(l.message, l.attendu));
  const tranche = (l: Ligne) => l.choix !== 'modele' && l.choix !== null && (seuil === null || l.confiance >= seuil);
  const justes = mesure.filter((l) => tranche(l) && l.choix === l.attendu).length;
  const fausses = mesure.filter((l) => tranche(l) && l.choix !== l.attendu);
  const n = mesure.length;
  console.log(`\n=== ${nom} — ${n} phrases ===`);
  console.log(`Bonne réponse sans Gemini : ${justes} (${pct(justes, n)})`);
  console.log(`Confiées à Gemini         : ${n - justes - fausses.length} (${pct(n - justes - fausses.length, n)})`);
  console.log(`MAUVAISE réponse servie   : ${fausses.length} (${pct(fausses.length, n)})`);
  // Les plus sûres d'abord : ce sont les plus dangereuses.
  const montrees = [...fausses].sort((a, b) => b.confiance - a.confiance).slice(0, 20);
  for (const l of montrees) {
    console.log(`   ✗ « ${l.message} » → ${l.choix}${seuil === null ? '' : ` (${l.confiance.toFixed(2)})`}, attendu : ${l.attendu}`);
  }
  if (fausses.length > montrees.length) console.log(`   … et ${fausses.length - montrees.length} autres`);

  // Par registre : où la méthode casse (SMS, fautes, vocal, pièges, langues locales).
  const registres = [...new Set(mesure.map((l) => l.registre))];
  if (registres.length > 1) {
    for (const r of registres) {
      const du = mesure.filter((l) => l.registre === r);
      const j = du.filter((l) => tranche(l) && l.choix === l.attendu).length;
      const f = du.filter((l) => tranche(l) && l.choix !== l.attendu).length;
      console.log(`   ${r.padEnd(9)} justes ${pct(j, du.length).padStart(5)} · fausses ${pct(f, du.length).padStart(5)}  (${du.length})`);
    }
  }
  const latences = lignes.map((l) => l.ms).filter((ms) => ms > 0);
  if (latences.length) console.log(`Latence (depuis ce poste) : médiane ${centile(latences, 50)} ms, p95 ${centile(latences, 95)} ms`);
  const cout = lignes.reduce((s, l) => s + l.cout, 0);
  if (cout > 0) console.log(`Coût                      : ${(cout / lignes.length * 1_000_000).toFixed(2)} $ par million de messages`);
  return { nom, justesSansGemini: justes, fausses: fausses.length, n, lignes };
}

const bilans: Bilan[] = [];

bilans.push(bilan('1. Détecteurs à mots (aujourd’hui)', JEU.map(([message, attendu, registre]) => ({
  message, attendu, registre, choix: baseTexte.get(message)!, confiance: 1, ms: 0, cout: 0,
})), null));

if (CLE_JEV) {
  const reponses = await enParallele(JEU, PARALLELE, ([m]) => classerIntention(m, { cle: CLE_JEV, modele: MODELE }));
  const echecs = reponses.filter((r) => r.erreur);
  if (echecs.length) console.log(`\n(Jev : ${echecs.length} appels en échec, ex. ${echecs[0]!.erreur})`);
  bilans.push(bilan(`2. Jev ${MODELE} (confiance ≥ ${SEUIL})`, JEU.map(([message, attendu, registre], i) => ({
    message, attendu, registre, choix: reponses[i]!.choix, confiance: reponses[i]!.confiance, ms: reponses[i]!.ms, cout: reponses[i]!.cout,
  })), SEUIL));
} else {
  console.log('\n(Jev non testé : OPENROUTER_API_KEY absente)');
}

if (process.env.GEMINI_API_KEY) {
  const temps: number[] = [];
  const vecteurs = await enParallele(JEU, PARALLELE, async ([m]) => {
    const debut = performance.now();
    const v = await embed(m, 'query');
    temps.push(performance.now() - debut);
    return v;
  });
  bilans.push(bilan(`3. Voisins sur embeddings (confiance ≥ ${SEUIL})`, JEU.map(([message, attendu, registre], i) => {
    const { choix, confiance } = voisins(i, vecteurs);
    return { message, attendu, registre, choix, confiance, ms: temps[i] ?? 0, cout: 0 };
  }), SEUIL));
} else {
  console.log('\n(Embeddings non testés : GEMINI_API_KEY absente)');
}

console.log('\n=== Face à face ===');
for (const b of bilans) {
  console.log(`${b.nom.padEnd(48)} justes sans Gemini ${pct(b.justesSansGemini, b.n).padStart(5)} · mauvaises servies ${b.fausses}`);
}
