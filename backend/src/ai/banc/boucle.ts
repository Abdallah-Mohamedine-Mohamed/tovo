import { normaliserIntention } from '../intents.js';
import type { Intention } from '../jev.js';
import { GUIDE_ETIQUETAGE, lireEtiquette, type Etiquette } from './guide.js';
import type { ModeleFort } from './modelesForts.js';

/**
 * La boucle du banc IA : de quoi faire grandir l'examen du cerveau EN
 * CONTINU (un passage par heure), avec de vraies phrases ET des milliers de phrases qu'aucun
 * client n'aurait encore écrites.
 *
 *   1. un modèle fort IMITE des clients (personnages, scénarios du métier,
 *      voix mal transcrite, haoussa, pièges…) et dit ce que chaque phrase
 *      veut dire ;
 *   2. un second modèle fort, d'une autre famille, étiquette les mêmes
 *      phrases SANS voir la première réponse ;
 *   3. seules les phrases où les deux sont d'accord entrent dans l'examen.
 *
 * Ce fichier ne touche ni à la base ni au réseau directement : les modèles
 * sont passés en paramètre (tests), le script scripts/banc-ia/boucle.ts fait le
 * reste.
 */

export interface PhraseEcrite {
  texte: string;
  intention: Intention;
  avant?: string | null;
  note?: string;
}

export interface Scenario {
  cle: string;
  consigne: string;
}

/** Les scénarios du métier. Chaque passage en parcourt une partie, à tour de rôle. */
export const SCENARIOS: Scenario[] = [
  { cle: 'repas', consigne: 'Commandes de repas : plats locaux (riz sauce, attiéké, dambou, kilishi, brochettes, doukounou, garba, fura…) et fast-food (tacos, burger, pizza, chawarma). Fautes d’orthographe, argot, messages très courts.' },
  { cle: 'courses', consigne: 'Courses : supermarché, marché (riz, huile, sucre, lait, oignons), pharmacie, beauté (pommade, mèches), électronique (écouteurs, chargeur), gaz. Quantités et formats (« un sac de 25 kg », « 2 litres »).' },
  { cle: 'voix', consigne: 'Messages VOCAUX mal transcrits : mots déformés (« du bon à checker » pour attiéké, « livret » pour livreur), hésitations (euh, bon, voilà), phrases longues et décousues, répétitions.' },
  { cle: 'livreur', consigne: 'Livreur et colis : envoyer un sac ou un document, aller chercher un téléphone chez quelqu’un, « j’ai une course », « il me faut une moto », avec ou sans quartier et numéro.' },
  { cle: 'suivi', consigne: 'Après une commande : retard, « il arrive quand ? », livreur injoignable, mauvaise commande, paiement Nita (« j’ai payé », « comment payer par Nita ? »), réclamations.' },
  { cle: 'panier', consigne: 'Ce qui est à l’écran et le panier : « le deuxième », « le moins cher », « enlève le jus », « annule le coca » (un article), « annule tout » (la commande), « comme d’habitude », « la même chose qu’hier ».' },
  { cle: 'pieges', consigne: 'PIÈGES de vocabulaire : livre / livreur / litre, paquet et colis de produits, « livre-moi deux pizzas », « envoie du riz chez ma mère », le métier de livreur (recrutement, « je suis livreur »), « Je viens livrer ».' },
  { cle: 'langues', consigne: 'Haoussa, zarma, et mélange avec le français (« Ina son abinci », « Ay ga baa ŋwaari », « wallahi je veux du poulet »). Donne dans la note la traduction.' },
  { cle: 'reponses', consigne: 'Réponses COURTES au dernier message de Tovo : un quartier, « oui », « le premier », « peu importe », une taille, un numéro. Remplis toujours « avant » avec le message de Tovo auquel la phrase répond.' },
  { cle: 'social', consigne: 'Salutations, remerciements, colère, blagues, questions sur Tovo (« c’est quoi Tovo ? », « vous êtes où ? »), questions hors sujet (une personne, la politique, la météo).' },
  { cle: 'boutiques', consigne: 'Enseignes nommées : voir une boutique, sa carte, si elle est ouverte, « je vais manger chez X », noms mal écrits ou dits à voix haute (« Garbador » pour Garba d’Or).' },
];

/**
 * Les scénarios d'un passage : `combien` à la suite, en tournant d'heure en
 * heure, pour que tous les scénarios reviennent régulièrement.
 */
export function scenariosDuPassage(quand: Date, combien: number): Scenario[] {
  const depart = Math.floor(quand.getTime() / 3_600_000) * combien;
  return Array.from({ length: Math.min(combien, SCENARIOS.length) }, (_, i) => SCENARIOS[(depart + i) % SCENARIOS.length]!);
}

/** Une même phrase (au même contexte) n'entre qu'une fois. */
export function cleDe(texte: string, avant?: string | null): string {
  return `${normaliserIntention(texte)}|${avant ? normaliserIntention(avant).slice(0, 80) : ''}`;
}

export interface ContexteMetier {
  boutiques: string[];
  produits: string[];
  quartiers: string[];
  /** Quelques phrases déjà dans l'examen : à ne pas recopier. */
  dejaVues: string[];
}

const SYSTEME_ECRIVAIN = [
  'Tu connais parfaitement la livraison à Niamey et la façon dont les gens y écrivent et parlent.',
  'Tu écris des messages que de VRAIS clients de Tovo enverraient dans le chat de l’app, pour construire',
  'l’examen de l’assistant. Varie les personnages (étudiant, mère de famille, commerçant, fonctionnaire',
  'pressé, personne âgée, jeune en argot), les longueurs, les fautes, le ton. Un tiers au moins des',
  'phrases doivent être DIFFICILES : pièges, formulations inhabituelles, mots déformés — mais avec une',
  'bonne réponse claire. Pas de phrase réellement ambiguë.',
  '',
  'Pour chaque phrase, donne l’intention selon ce guide :',
  GUIDE_ETIQUETAGE,
].join('\n');

export function demandeEcrivain(scenario: Scenario, combien: number, contexte: ContexteMetier): string {
  return [
    `Scénario : ${scenario.consigne}`,
    '',
    `Écris ${combien} messages différents pour ce scénario.`,
    `Enseignes réelles de Tovo : ${contexte.boutiques.join(', ')}.`,
    `Produits réels : ${contexte.produits.join(', ')}.`,
    `Quartiers : ${contexte.quartiers.join(', ')}.`,
    contexte.dejaVues.length ? `Déjà dans l’examen (ne les recopie pas, ne les paraphrase pas) : ${contexte.dejaVues.map((p) => `« ${p} »`).join(' ; ')}.` : '',
    '',
    'Réponds en JSON : {"phrases": [{"texte": "…", "intention": "<clé>", "avant": "<dernier message de Tovo, ou null>", "note": "<personnage, et pourquoi c’est difficile>"}]}',
  ].join('\n');
}

export function lirePhrasesEcrites(json: unknown): PhraseEcrite[] {
  const liste = (json as { phrases?: unknown })?.phrases;
  if (!Array.isArray(liste)) return [];
  const sortie: PhraseEcrite[] = [];
  for (const p of liste as Array<Record<string, unknown>>) {
    const texte = typeof p.texte === 'string' ? p.texte.trim() : '';
    const intention = lireEtiquette(p.intention);
    if (!texte || texte.length > 500 || !intention || intention === 'ambigu') continue;
    sortie.push({
      texte,
      intention,
      avant: typeof p.avant === 'string' && p.avant.trim() ? p.avant.trim() : null,
      ...(typeof p.note === 'string' ? { note: p.note.slice(0, 300) } : {}),
    });
  }
  return sortie;
}

export async function ecrirePhrases(
  ecrivain: ModeleFort,
  scenario: Scenario,
  combien: number,
  contexte: ContexteMetier,
): Promise<PhraseEcrite[]> {
  return lirePhrasesEcrites(await ecrivain.json(SYSTEME_ECRIVAIN, demandeEcrivain(scenario, combien, contexte)));
}

/** Le juge étiquette, sans jamais voir l'étiquette de l'écrivain. */
export async function etiqueterALAveugle(
  juge: ModeleFort,
  phrases: Array<{ texte: string; avant?: string | null }>,
): Promise<Array<Etiquette | null>> {
  if (phrases.length === 0) return [];
  const demande = [
    'Étiquette chacun de ces messages.',
    JSON.stringify(phrases.map((p, id) => ({ id, avant: p.avant ?? null, texte: p.texte }))),
    'Réponds en JSON : {"etiquettes": [{"id": 0, "intention": "<clé ou ambigu>"}]}',
  ].join('\n');
  const json = (await juge.json(GUIDE_ETIQUETAGE, demande)) as { etiquettes?: Array<{ id?: number; intention?: unknown }> };
  const resultat: Array<Etiquette | null> = phrases.map(() => null);
  for (const e of json?.etiquettes ?? []) {
    if (typeof e.id === 'number' && e.id >= 0 && e.id < phrases.length) resultat[e.id] = lireEtiquette(e.intention);
  }
  return resultat;
}

/**
 * Livreur et colis déclenchent la MÊME course : leur désaccord n'en est pas
 * un (même règle que le bilan du banc).
 */
export function memeSens(a: Etiquette | null, b: Etiquette | null): boolean {
  if (!a || !b || a === 'ambigu' || b === 'ambigu') return false;
  const course = (i: Etiquette) => (i === 'livreur' || i === 'colis' ? 'course' : i);
  return course(a) === course(b);
}
