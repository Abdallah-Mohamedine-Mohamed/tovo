import { env } from '../config/env.js';
import { INTENTIONS, type Intention } from './jev.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';
import { blocExemples, type Exemple } from './banc/exemples.js';
import { CONSTITUTION } from './constitution.js';
import { vocabulairePourCerveau } from './vocabulaireLocal.js';

/**
 * Le cerveau : un modèle COMPREND le message et décide de la route.
 *
 * Remplace la cascade classifieur local + Jev, qui devinait sur les mots :
 * « Je veux devenir livreur » commandait un livreur, « un colis de riz »
 * ouvrait un envoi de colis. Banc du 26/09 (scripts/banc-ia, 193 phrases
 * réelles et pièges) avec CETTE consigne : Flash-Lite 3.1 sans réflexion,
 * 96 % de justesse et AUCUNE action coûteuse à tort, contre 85 % et 6 pour la
 * cascade — en 0,9 s de médiane.
 *
 * Vitesse : la réponse tient en quelques mots (un JSON court), sans
 * réflexion interne, et trois filets coupent la traîne lente et les pannes :
 *   1. relance — sans réponse au bout de CERVEAU_RELANCE_MS, un second
 *      modèle (Flash-Lite 3.5, 0,7 s) part en parallèle : le premier qui
 *      répond gagne ;
 *   2. panne — une erreur de Google lance aussitôt le suivant, sans attendre ;
 *   3. dernier recours — OpenAI si les deux modèles Google échouent.
 * Au-delà de CERVEAU_DELAI_MAX_MS : `intention: null`, le chemin habituel
 * reprend (il ne déclenche jamais d'action coûteuse sans confirmation).
 *
 * Ne lève jamais.
 */

export const COUTEUSES = new Set<Intention>(['livreur', 'colis', 'annuler', 'habitude']);

/**
 * Les rayons du catalogue où chercher (02/10), et leur catégorie racine.
 * « huile » mélangeait Huile Dinor (supermarché) et huiles d'argan (beauté) :
 * le cerveau dit dans quel rayon le client cherche, la recherche y reste.
 */
export const RAYONS = ['repas', 'supermarche', 'marche', 'beaute', 'electronique', 'vetements', 'gaz', 'pharmacie'] as const;
export type Rayon = typeof RAYONS[number];

/**
 * Les types de commerce qu'un client peut chercher (« un supermarché pas loin
 * », « les pharmacies du coin », 05/10). Mêmes noms que l'annuaire public
 * (services/commerces.ts) ; certains ont aussi un rayon sur Tovo.
 */
export const COMMERCES = ['supermarche', 'marche', 'pharmacie', 'restaurant', 'boulangerie', 'boucherie',
  'grillades', 'beaute', 'electronique', 'vetements', 'quincaillerie'] as const;
export type TypeCommerceCherche = typeof COMMERCES[number];
/** Le rayon Tovo d'un type de commerce, s'il en a un. */
export const RAYON_DU_COMMERCE: Partial<Record<TypeCommerceCherche, Rayon>> = {
  supermarche: 'supermarche', marche: 'marche', pharmacie: 'pharmacie', restaurant: 'repas',
  beaute: 'beaute', electronique: 'electronique', vetements: 'vetements',
};
export const SLUG_DU_RAYON: Record<Rayon, string> = {
  repas: 'restaurants-m3', supermarche: 'grocery-m4', marche: 'kasuwa-m10', beaute: 'beaute-soins',
  electronique: 'electronique', vetements: 'vetements', gaz: 'gaz-m12', pharmacie: 'parapharmacies-m5',
};

/**
 * La consigne. Exportée : le banc (scripts/banc-ia) mesure EXACTEMENT celle-ci.
 *
 * Les exemples ne reprennent pas les phrases du banc : ils enseignent la
 * règle, le banc vérifie qu'elle est comprise sur d'autres phrases.
 */
export const CONSIGNE_CERVEAU = [
  'Tu comprends les messages des clients de Tovo, une application de livraison à Niamey (Niger) : repas, courses et colis.',
  'Tu ne réponds pas au client : tu dis seulement ce qu’il veut faire.',
  '',
  CONSTITUTION,
  '',
  'Intentions possibles :',
  ...Object.entries(INTENTIONS).map(([cle, def]) => `- ${cle} : ${def}`),
  '',
  'Règles :',
  '- livreur / colis : le client veut qu’un livreur SE DÉPLACE pour lui (venir le voir, aller chercher ou déposer un objet à lui). Faire livrer un PRODUIT du catalogue, même avec « livre-moi », « apporte-moi » ou « envoie … chez ma mère », c’est recherche.',
  '- Un objet qui ressemble à un mot de livraison reste un produit : un livre, un litre, un paquet de biscuits, un sac ou un « colis » de riz → recherche.',
  '- Tovo ne transporte PAS de personnes : un taxi, un Uber, « emmène-moi à l’aéroport », « ramène-moi à la maison » (c’est le client qui se déplace) → social. Un livreur vient pour un OBJET ou une course.',
  '- Les demandes d’assistant personnel (alarme, agenda, liste de tâches, musique, météo, lumière) → social.',
  '- Où en est la commande, quand elle arrive, où est le livreur → suivi. Un PROBLÈME (mauvaise commande, article manquant, livreur qui ne répond pas, monnaie, paiement Nita bloqué, modifier ou compléter une commande déjà passée) → aide.',
  '- question : SEULEMENT le service Tovo lui-même (frais de livraison, zones desservies, horaires de livraison, comment payer, devenir livreur ou boutique partenaire). Une question sur ce que Tovo PROPOSE (boutiques ouvertes, produits, catégories, prix d’un produit) → envie, recherche ou boutique, jamais question.',
  '- Remercier, saluer, bavarder, parler à l’assistant de lui-même ou de ce qu’il vient de dire (« d’où tu tiens ça ? », « tu connais ? », « tu es bête ») → social.',
  '- annuler : annuler TOUTE la commande. Retirer ou changer UN article du panier ou de l’écran, avant de commander (« enlève le jus », « annule la fanta », « pas de frites ») → designe. Ajouter ou changer quelque chose sur une commande DÉJÀ passée (« ajoutez un coca à ma commande en cours ») → aide. Voir ou valider son panier → panier.',
  '- Il veut parler à une personne de Tovo, se plaint que Tovo ne l’aide pas, ou répète une demande qui a échoué → aide (article 15 : on transmet à l’équipe).',
  '- Une question de santé ou sur un médicament (douleur, dose, quel remède) → recherche du médicament ou de la pharmacie (article 12 : on dit où le trouver, sans conseil), jamais aide : ce n’est pas une réclamation.',
  '- « J’ai changé d’avis » sans préciser : il veut annuler ou modifier → annuler avec « sur » : false.',
  '- Il demande une moto ou un coursier pour une course, sans dire qu’il veut être transporté lui-même (« il me faut une moto tout de suite ») → livreur.',
  '- Un message court qui répond à la question précédente de Tovo s’interprète avec elle (un quartier après « Où récupérer le colis ? » → livreur).',
  '- L’« État » (ce qui est à l’écran, ce qui attend une réponse, s’il y a une commande en cours) décide du sens d’un message court (article 2). Une précision ou un changement sur ce que le client est en train de choisir → designe. Renoncer à ce qui est à l’écran sans commande en cours → social, jamais annuler (article 3).',
  '- Fautes, français parlé, transcriptions vocales approximatives, haoussa et zarma : comprends le sens.',
  `- Plats et aliments locaux, souvent déformés par la transcription vocale (entre guillemets) : ${vocabulairePourCerveau()}. Quand le message en contient une forme déformée, écris le VRAI nom dans « produit ».`,
  '',
  'Exemples :',
  '« Je suis coursier, vous recrutez ? » → question',
  '« On m’a livré du poulet alors que j’ai pris du poisson » → aide',
  '« C’est combien la livraison à Kalley ? » → question',
  '« Quels restaurants sont ouverts là ? » → envie',
  '« Je veux payer maintenant » → panier',
  '« Apporte-moi des brochettes » → recherche',
  '« un sac de sucre de 50 kg » → recherche',
  '« Le coursier ne décroche pas » → aide',
  '« J’ai un sac à faire déposer à Gamkalley » → colis',
  '« Retire la fanta » → designe',
  '« Viens me voir, j’ai une course » → livreur',
  '« Appelle-moi un taxi pour la gare » → social',
  '',
  '« sur » : false si la phrase peut raisonnablement vouloir dire autre chose, surtout si l’une des lectures est une action (livreur, colis, annuler, habitude).',
  '« produit » : ce que le client cherche, en 1 à 5 mots, EN FRANÇAIS quelle que soit la langue du client (le catalogue est en français), tel qu’on le taperait dans le catalogue — le produit ou le plat (« merguez », « pommade Nivea », « riz parfumé »), ou la boutique nommée avec ce qui la précise (« O’Takoss Centre Aéré »). Sans les mots de politesse ni de demande (« je veux », « bien », « autre chose »). Si le message répond au dernier message de Tovo, complète avec lui (après « Dans quel quartier cherchez-vous du poulet ? », « Bobiel » → « poulet »). Vide s’il ne cherche rien.',
  '« rayon » : où chercher ce produit dans Tovo — repas (plats préparés, restaurants), supermarche (épicerie, boissons, produits ménagers, huile de cuisine, lait, riz en sac), marche (produits frais du marché), beaute (soins, cosmétiques, parfums), electronique (téléphones, accessoires, électroménager), vetements (habits, chaussures, montres, bijoux), gaz, pharmacie (parapharmacie, médicaments sans ordonnance) ; « aucun » si rien ne convient ou si c’est une boutique nommée. Choisis selon ce que le client VEUT : « un litre d’huile » → supermarche (pas beaute), « deux litres de lait » → supermarche.',
  '« commerce » : le TYPE de commerce que le client cherche, s’il demande des commerces d’un genre plutôt qu’un produit ou une boutique nommée (« un supermarché pas loin », « les pharmacies du coin », « tous les supermarchés de Niamey ») ; « aucun » sinon. Il peut aussi dire ce qu’il veut y trouver (« produit »).',
  '« suite » : true si le client veut d’AUTRES résultats que ceux déjà montrés pour la même chose (d’autres, encore, plus, plus loin, ailleurs, d’autres vendeurs) — article 7. « produit » reste alors ce qu’il cherchait.',
  '« depart », « arrivee », « telephone » : ce que le client a précisé pour une course (article 9), mot pour mot, chaîne vide sinon : « depart » = où le livreur prend quelque chose, si ce n’est pas chez le client ; « arrivee » = où il doit l’apporter (« à mon frère à Yantala » → « Yantala ») ; « telephone » = un numéro dit.',
  '« precision » : la préférence que le client vient de dire sur ce qu’il choisit ou commande (« sans oignons », « bien cuit », « sonnez en arrivant »), mot pour mot ; chaîne vide s’il n’en dit pas. Jamais le choix d’un article (« le premier »).',
  'Réponds uniquement en JSON : {"intention": "<clé>", "sur": true|false, "produit": "<mots>", "rayon": "<rayon>", "commerce": "<type>", "precision": "<texte ou vide>", "depart": "<lieu ou vide>", "arrivee": "<lieu ou vide>", "telephone": "<numéro ou vide>", "suite": true|false}.',
].join('\n');

export interface ContexteCerveau {
  /** Le dernier message de Tovo : ce à quoi le client répond peut-être. */
  avant?: string | null;
  /**
   * L'état du parcours (article 2) : ce qui est à l'écran, ce qui attend une
   * réponse, s'il y a une commande en cours. Voir etat.ts.
   */
  etat?: string | null;
  /**
   * Les phrases validées de la banque les plus proches, et ce qu'elles
   * voulaient dire (ai/banc/exemples.ts).
   */
  exemples?: Exemple[];
}

export interface DecisionCerveau {
  intention: Intention | null;
  sur: boolean;
  /**
   * Ce que le client cherche, extrait par le cerveau (02/10) : « merguez »
   * dans « On y va sur autre chose. Je veux manger du bon merguez ». Remplace
   * le découpage à mots du code, qui gardait « autre chose bon merguez ».
   */
  produit?: string;
  /** Où chercher ce produit dans le catalogue (« supermarche » pour l'huile de cuisine). */
  rayon?: Rayon;
  /** Le type de commerce cherché (« un supermarché pas loin »), s'il y en a un. */
  commerce?: TypeCommerceCherche;
  /** Le client veut d'autres résultats que ceux déjà montrés (article 7). */
  suite?: boolean;
  /** Ce qu'il a précisé et qu'une carte doit reprendre (article 9). */
  details?: Details;
  /** Le modèle qui a répondu le premier, ou null. */
  modele: string | null;
  ms: number;
  /** Un second modèle a-t-il été lancé ? */
  relance: boolean;
  erreurs: string[];
}

/** Ce que le client a précisé, mot pour mot (article 9). */
export interface Details { depart?: string; arrivee?: string; telephone?: string; precision?: string }
export type Lecture = { intention: Intention; sur: boolean; produit?: string; rayon?: Rayon; commerce?: TypeCommerceCherche; suite?: boolean; details?: Details };
export type Essai = (message: string, signal: AbortSignal) => Promise<Lecture>;

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    intention: { type: 'STRING', enum: Object.keys(INTENTIONS) },
    sur: { type: 'BOOLEAN' },
    produit: { type: 'STRING' },
    rayon: { type: 'STRING', enum: ['aucun', ...RAYONS] },
    commerce: { type: 'STRING', enum: ['aucun', ...COMMERCES] },
    // Au premier niveau et obligatoire (vide s'il n'y en a pas) : rangée dans
    // « details », facultatif, elle était omise deux fois sur trois (05/10).
    precision: { type: 'STRING' },
    // Idem pour la course : dans un sous-objet facultatif, la destination
    // était omise (« clés à mon frère à Yantala » : 4 fois sur 4, 05/10).
    depart: { type: 'STRING' },
    arrivee: { type: 'STRING' },
    telephone: { type: 'STRING' },
    suite: { type: 'BOOLEAN' },
    details: {
      type: 'OBJECT',
      properties: {
        depart: { type: 'STRING' }, arrivee: { type: 'STRING' }, telephone: { type: 'STRING' }, precision: { type: 'STRING' },
      },
    },
  },
  // « commerce » obligatoire : facultatif, Flash-Lite l'omettait (05/10).
  required: ['intention', 'sur', 'commerce', 'precision', 'depart', 'arrivee', 'telephone'],
};

export function lireDecision(texte: string): Lecture | null {
  const brut = texte.match(/\{[\s\S]*\}/)?.[0];
  if (!brut) return null;
  try {
    const v = JSON.parse(brut) as { intention?: string; sur?: unknown; produit?: unknown; rayon?: unknown; commerce?: unknown; precision?: unknown; depart?: unknown; arrivee?: unknown; telephone?: unknown; suite?: unknown; details?: unknown };
    if (!v.intention || !(v.intention in INTENTIONS)) return null;
    const produit = typeof v.produit === 'string' ? v.produit.trim().slice(0, 80) : '';
    const rayon = (RAYONS as readonly string[]).includes(String(v.rayon)) ? v.rayon as Rayon : undefined;
    // « sur » absent (le secours OpenAI n'a pas de schéma imposé) : PAS sûr.
    // Une action coûteuse passe alors par les tuiles, jamais directement.
    // Les précisions au premier niveau (obligatoires, vides s'il n'y a rien),
    // et l'ancien sous-objet « details » si un modèle le donne encore.
    const haut = Object.fromEntries((['precision', 'depart', 'arrivee', 'telephone'] as const)
      .map((cle) => [cle, typeof v[cle] === 'string' ? (v[cle] as string).trim() : ''])
      .filter(([, valeur]) => valeur));
    const details = lireDetails({ ...((v.details && typeof v.details === 'object') ? v.details as object : {}), ...haut });
    // « supermarché » ou « supermarche », « Pharmacies » : accents, casse et pluriel tolérés.
    const brutCommerce = String(v.commerce ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/s$/, '');
    const commerce = (COMMERCES as readonly string[]).includes(brutCommerce) ? brutCommerce as TypeCommerceCherche : undefined;
    return {
      intention: v.intention as Intention, sur: v.sur === true,
      ...(produit ? { produit } : {}), ...(rayon ? { rayon } : {}),
      ...(commerce ? { commerce } : {}),
      ...(v.suite === true ? { suite: true } : {}), ...(details ? { details } : {}),
    };
  } catch {
    return null;
  }
}

/**
 * ARTICLE 5 garanti : une précision n'est gardée que si le client l'a DITE
 * (dans son message, ou dans ce à quoi il répond). Un numéro doit s'y
 * trouver chiffre pour chiffre ; un lieu ou une préférence, par au moins un
 * de ses mots. Vu le 05/10 : le cerveau inventait « 0000000000 » comme
 * téléphone, une fois sur trois.
 */
/**
 * Le même principe pour le TYPE de commerce : il n'est retenu que si le
 * client l'a nommé. Obligé de remplir le champ, le cerveau mettait
 * « restaurant » pour « pizza » ou « Otakoss », et Tovo listait des
 * restaurants au lieu des pizzas (05/10). Les mots qui désignent chaque type,
 * sous leurs formes courantes à Niamey.
 */
const NOMS_DU_COMMERCE: Record<TypeCommerceCherche, RegExp> = {
  supermarche: /\b(super ?march|supermarket|superette|market|alimentation|epicerie)/,
  marche: /\bmarches?\b/,
  pharmacie: /\b(pharmacie|pharma\b|officine)/,
  restaurant: /\b(restaurant|resto|maquis|gargote|cantine)/,
  boulangerie: /\b(boulanger|patisser)/,
  boucherie: /\b(boucher)/,
  grillades: /\b(grill|dibiterie|rotisserie)/,
  beaute: /\b(beaute|cosmetique|salon de)/,
  electronique: /\b(electronique|magasin de telephone|boutique de telephone)/,
  vetements: /\b(vetement|habit|friperie|boutique de mode|tailleur)/,
  quincaillerie: /\b(quincaill)/,
};
export function commerceNomme(type: TypeCommerceCherche, message: string): boolean {
  const n = message.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  return NOMS_DU_COMMERCE[type].test(n);
}

export function detailsDits(details: Details | undefined, message: string, avant: string): Details | undefined {
  if (!details) return undefined;
  const dit = `${message} ${avant}`;
  const chiffres = dit.replace(/\D/g, '');
  const mots = new Set(dit.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').split(/[^a-z0-9]+/).filter((m) => m.length >= 3));
  const motsDe = (t: string) => t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').split(/[^a-z0-9]+/).filter((m) => m.length >= 3);
  const garde: Details = {};
  for (const [cle, valeur] of Object.entries(details) as Array<[keyof Details, string]>) {
    const vrai = cle === 'telephone'
      ? valeur.replace(/\D/g, '').length >= 8 && chiffres.includes(valeur.replace(/\D/g, '').replace(/^227/, ''))
      : motsDe(valeur).some((m) => mots.has(m));
    if (vrai) garde[cle] = valeur;
  }
  return Object.keys(garde).length ? garde : undefined;
}

/** Les précisions, nettoyées : seulement des chaînes non vides et courtes. */
function lireDetails(brut: unknown): Details | undefined {
  if (!brut || typeof brut !== 'object') return undefined;
  const d: Details = {};
  for (const cle of ['depart', 'arrivee', 'telephone', 'precision'] as const) {
    const v = (brut as Record<string, unknown>)[cle];
    if (typeof v === 'string' && v.trim()) d[cle] = v.trim().slice(0, 160);
  }
  return Object.keys(d).length ? d : undefined;
}

/** Le texte envoyé au modèle : le message, ce à quoi il répond, et l'état de l'écran. */
export function messagePourCerveau(message: string, contexte: ContexteCerveau = {}): string {
  const avant = contexte.avant?.replace(/\s+/g, ' ').trim().slice(0, 300);
  const etat = contexte.etat?.trim().slice(0, 700);
  const base = avant ? `Dernier message de Tovo : « ${avant} »\nMessage du client : « ${message} »` : message;
  const texte = etat ? `État : ${etat}\n${avant ? base : `Message du client : « ${message} »`}` : base;
  const exemples = blocExemples(contexte.exemples ?? []);
  return exemples ? `${exemples}\n\n${avant || etat ? texte : `Message du client : « ${message} »`}` : texte;
}

/**
 * Réflexion interne du modèle. « aucune » : réponse directe (budget 0) —
 * mesuré le 26/09, Flash-Lite 3.1 répond alors en ~0,8 s au lieu de 1,2 s.
 * La réflexion compte dans les jetons de sortie : trop courts, elle coupait
 * la réponse (« MAX_TOKENS », JSON illisible).
 */
export type Reflexion = 'aucune' | 'courte' | 'low';

function reglageReflexion(r: Reflexion): Record<string, unknown> {
  if (r === 'aucune') return { thinkingBudget: 0 };
  if (r === 'courte') return { thinkingBudget: 128 };
  return { thinkingLevel: 'low' };
}

export function essaiGemini(modele: string, reflexion: Reflexion = 'low'): Essai {
  return async (message, signal) => {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY! },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: CONSIGNE_CERVEAU }] },
        contents: [{ role: 'user', parts: [{ text: message }] }],
        generationConfig: {
          maxOutputTokens: 1024,
          responseMimeType: 'application/json',
          responseSchema: SCHEMA,
          thinkingConfig: reglageReflexion(reflexion),
        },
      }),
      signal,
      ...viaLigneGoogle,
    });
    const corps = (await r.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
      error?: { message?: string };
    };
    if (!r.ok) throw new Error(`${modele} ${r.status} ${corps.error?.message?.slice(0, 120) ?? ''}`);
    const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
    const d = lireDecision(texte);
    if (!d) throw new Error(`${modele} : réponse illisible`);
    return d;
  };
}

function openai(modele: string): Essai {
  return async (message, signal) => {
    const raisonne = /^(gpt-5|o\d)/.test(modele);
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY}` },
      body: JSON.stringify({
        model: modele,
        messages: [{ role: 'system', content: CONSIGNE_CERVEAU }, { role: 'user', content: message }],
        response_format: { type: 'json_object' },
        ...(raisonne
          ? { reasoning_effort: /^gpt-5(\.1)?(-|$)/.test(modele) ? 'minimal' : 'none' }
          : { temperature: 0 }),
      }),
      signal,
    });
    const corps = (await r.json()) as { choices?: Array<{ message?: { content?: string } }>; error?: { message?: string } };
    if (!r.ok) throw new Error(`${modele} ${r.status} ${corps.error?.message?.slice(0, 120) ?? ''}`);
    const d = lireDecision(corps.choices?.[0]?.message?.content ?? '');
    if (!d) throw new Error(`${modele} : réponse illisible`);
    return d;
  };
}

/** « gemini-3.1-flash-lite:aucune » → le modèle et sa réflexion. */
export function lireReglage(reglage: string): [string, Reflexion] {
  const [modele, reflexion] = reglage.split(':');
  const r = reflexion === 'aucune' || reflexion === 'courte' ? reflexion : 'low';
  return [modele!, r];
}

export const cerveauActif = (): boolean => env.AIGUILLAGE === 'cerveau' && Boolean(env.GEMINI_API_KEY);

/** Les modèles dans l'ordre : le principal, la relance, le dernier recours. */
function essais(): Array<[string, Essai]> {
  const liste: Array<[string, Essai]> = [];
  if (env.GEMINI_API_KEY) {
    for (const reglage of new Set([env.CERVEAU_MODELE, env.CERVEAU_RELANCE_MODELE])) {
      const [modele, reflexion] = lireReglage(reglage);
      liste.push([modele, essaiGemini(modele, reflexion)]);
    }
  }
  if (env.OPENAI_API_KEY && env.CERVEAU_SECOURS_OPENAI) {
    liste.push([env.CERVEAU_SECOURS_OPENAI, openai(env.CERVEAU_SECOURS_OPENAI)]);
  }
  return liste;
}

export interface OptionsCerveau {
  relanceMs?: number;
  delaiMaxMs?: number;
  /** Pour les tests : remplace les vrais modèles. */
  essais?: Array<[string, Essai]>;
}

export async function comprendre(
  message: string,
  contexte: ContexteCerveau = {},
  options: OptionsCerveau = {},
): Promise<DecisionCerveau> {
  const debut = performance.now();
  const liste = options.essais ?? essais();
  const relanceMs = options.relanceMs ?? env.CERVEAU_RELANCE_MS;
  const delaiMaxMs = options.delaiMaxMs ?? env.CERVEAU_DELAI_MAX_MS;
  const texte = messagePourCerveau(message, contexte);
  const erreurs: string[] = [];
  const controleur = new AbortController();
  const vide = (): DecisionCerveau => ({
    intention: null, sur: false, modele: null, ms: performance.now() - debut, relance: lances > 1, erreurs,
  });
  let lances = 0;
  if (liste.length === 0 || !message.trim()) return vide();

  return new Promise<DecisionCerveau>((resoudre) => {
    let fini = false;
    let enCours = 0;
    let minuterie: ReturnType<typeof setTimeout> | undefined;
    const terminer = (d: DecisionCerveau) => {
      if (fini) return;
      fini = true;
      clearTimeout(minuterie);
      clearTimeout(plafond);
      controleur.abort();
      resoudre(d);
    };
    const plafond = setTimeout(() => {
      erreurs.push(`aucune réponse en ${delaiMaxMs} ms`);
      terminer(vide());
    }, delaiMaxMs);

    const lancerSuivant = () => {
      if (fini) return;
      clearTimeout(minuterie);
      const suivant = liste[lances];
      if (!suivant) {
        if (enCours === 0) terminer(vide());
        return;
      }
      lances++;
      enCours++;
      const [modele, essai] = suivant;
      // Le suivant part à son tour si celui-ci traîne.
      minuterie = setTimeout(lancerSuivant, relanceMs);
      essai(texte, controleur.signal).then(
        (d) => {
          // Article 5 : une précision n'est gardée que si le client l'a DITE.
          const details = detailsDits(d.details, message, contexte.avant ?? '');
          // Le type de commerce aussi : seulement s'il est NOMMÉ.
          const commerce = d.commerce && commerceNomme(d.commerce, message) ? d.commerce : undefined;
          const { details: _brut, commerce: _type, ...reste } = d;
          terminer({ ...reste, ...(details ? { details } : {}), ...(commerce ? { commerce } : {}), modele, ms: performance.now() - debut, relance: lances > 1, erreurs });
        },
        (cause: unknown) => {
          enCours--;
          if (fini) return;
          erreurs.push((cause as Error)?.message?.slice(0, 160) ?? String(cause));
          // En panne : inutile d'attendre la minuterie.
          lancerSuivant();
        },
      );
    };
    lancerSuivant();
  });
}
