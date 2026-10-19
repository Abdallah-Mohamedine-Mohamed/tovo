import { env } from '../config/env.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';
import type { Component } from '../components/builders.js';
import { Faits, verifierTexte } from './verificateur.js';
import { CONSTITUTION } from './constitution.js';

/**
 * Le RÉDACTEUR (02/10) : aucune phrase adressée au client n'est écrite par du
 * code. Les chemins rapides trouvent vite (produits, commerces, pharmacies,
 * panier, livreur…) ; la phrase, elle, est rédigée par une IA à partir du
 * message EXACT du client et de ce qui a été trouvé.
 *
 * Pourquoi : les phrases à trous du code répondaient à côté — « Tovo ne
 * propose pas encore de bien manger des merguez », « 1278 produits
 * correspondent » à « Tu es sourd ? ». Les clients diront des milliers de
 * phrases différentes : on ne les corrige pas une par une.
 *
 * Le modèle est celui du cerveau (Flash-Lite, sans réflexion, ~0,5–1 s). Le
 * vérificateur anti-invention passe sur sa phrase : aucun nom, prix, nombre
 * ou durée qui ne vienne des faits. S'il ne répond pas à temps, ou invente,
 * la phrase prévue sert de secours.
 */

const CONSIGNE = [
  'Tu es Tovo, l’assistant d’une application de livraison à Niamey (Niger) : repas, courses, colis, livreurs.',
  'Tu écris UNE réponse courte (1 ou 2 phrases) au dernier message du client : français simple, chaleureux, vouvoiement.',
  '',
  CONSTITUTION,
  '',
  'Sous ta phrase, l’application affiche déjà les cartes (produits, boutiques, commerces, boutons) : ne les énumère pas, présente-les en une phrase.',
  'Tu reçois : le message du client, ce que Tovo a trouvé (faits), et le SENS de la réponse prévue.',
  'Garde ce sens (une question reste une question, une confirmation reste une confirmation, une absence reste une absence),',
  'mais écris avec tes propres mots, en répondant à ce que le client a vraiment dit.',
  '',
  'Règles strictes :',
  '- N’invente RIEN : aucun nom, prix, nombre, distance, durée, horaire ou promesse absent des faits.',
  '- Ne recopie pas la phrase du client, et ne reprends pas ses mots parasites (« bien », « svp », « je voudrais »).',
  '- Ne donne un nombre de résultats que s’il aide vraiment le client.',
  '- Si le message du client n’a rien à voir avec les cartes trouvées (une remarque, une plainte, une blague), réponds d’abord à ce qu’il a dit.',
  '- Pas de liste, pas de titre ; **gras** seulement pour un nom de produit, de boutique ou de commerce présent dans les faits.',
  '- Pas de question si la réponse prévue n’en pose pas.',
  '- S’il n’y a AUCUNE carte, ne dis jamais « voici », « ci-dessous », « découvrez » : rien ne s’affiche sous ta phrase.',
  '- Sur Tovo lui-même (recrutement, contacts, horaires, adresses, procédures), ne dis que ce qui est dans les faits.',
  '- Si les faits ont « autour_de », les commerces hors Tovo ont été choisis au plus près de CE lieu, sans y être forcément : dis « vers Yantala » ou « les plus proches de Yantala », jamais « à Yantala » sauf pour un commerce dont le quartier est Yantala ; les boutiques Tovo, elles, ne sont pas choisies selon ce lieu. Leurs distances, elles, se comptent depuis le client (« à 2,9 km de vous »). Ce lieu ne concerne que les commerces : les produits Tovo ne sont pas choisis selon lui, ne dis jamais qu’ils sont « autour de » ce lieu.',
].join('\n');

/**
 * Une phrase qui annonce des cartes (« Voici les autres options ») alors qu'il
 * n'y en a aucune : retirée, quel que soit l'auteur (rédacteur ou assistant).
 * Mesuré le 02/10 : un défaut fréquent des deux.
 */
export function sansPromesseVide(texte: string, composants: Component[]): string {
  if (composants.length > 0) return texte;
  const annonce = /\b(voici|voila|ci-dessous|ci dessous|découvrez|decouvrez|parcourez|consultez ces|vous pouvez (?:parcourir|explorer|découvrir|consulter))\b/i;
  const phrases = texte.match(/[^.!?\n]+[.!?]*\s*/g) ?? [texte];
  const resultat = phrases.filter((p) => !annonce.test(p)).join('').trim();
  return resultat || texte;
}

/** Ce que les cartes montrent, en bref : les noms suffisent au rédacteur. */
function resumeCartes(composants: Component[]): unknown[] {
  return composants.slice(0, 4).map((c) => {
    const d = c.data as Record<string, unknown>;
    const items = Array.isArray(d.items) ? (d.items as Array<Record<string, unknown>>).slice(0, 6) : [];
    return {
      type: c.type,
      ...(d.name ? { nom: d.name } : {}),
      ...(items.length ? { elements: items.map((i) => i.name ?? i.nom ?? i.label ?? i.title).filter(Boolean) } : {}),
      ...(typeof d.total === 'number' ? { total: d.total } : {}),
    };
  });
}

export interface ARediger {
  /** Le message exact du client. */
  message: string;
  /** La phrase prévue par le code : son SENS, et le secours. */
  prevue: string;
  /** Ce que l'outil a trouvé (résumé). */
  faits?: unknown;
  composants?: Component[];
  /** Le dernier message de Tovo, s'il y en a un (le client y répond peut-être). */
  avant?: string | null;
}

/**
 * La phrase pour le client. Jamais d'erreur : en cas de panne, de délai ou
 * d'invention, la phrase prévue.
 */
export async function rediger(r: ARediger, delaiMs = 2500): Promise<string> {
  return (await redigerEtJuger(r, delaiMs, false)).texte;
}

/**
 * La phrase, ET le jugement sur les produits trouvés : répondent-ils vraiment
 * à ce que le client veut ? (02/10) La recherche trouve le MOT, pas le sens :
 * « deux litres de lait » ramenait des savons au lait. Le jugement est fait
 * PRODUIT PAR PRODUIT : `garder` = les identifiants de ceux qui répondent ;
 * `pertinent` = au moins un. Un verdict global rejetait toute une liste de
 * merguez parce que des tacos s'y mêlaient (« Nous ne proposons pas de
 * merguez » — faux, 02/10). null s'il n'a pas pu se faire (panne, délai).
 *
 * Deux appels EN PARALLÈLE, pas un seul : demandé dans le même appel que la
 * phrase, le jugement était noyé (« livres pour enfants » → une console de jeu
 * « pertinente ») ; posé seul, le même modèle répond juste (mesuré le 02/10).
 * Le temps ne change pas : les deux partent ensemble.
 */
export async function redigerEtJuger(
  r: ARediger,
  delaiMs = 2500,
  juger = true,
): Promise<{ texte: string; pertinent: boolean | null; garder: ReadonlySet<string> | null }> {
  const [texte, jugement] = await Promise.all([
    appeler(r, delaiMs),
    juger ? jugerPertinence(r, delaiMs) : Promise.resolve(null),
  ]);
  return { texte: texte ?? r.prevue.trim(), pertinent: jugement ? jugement.size > 0 : null, garder: jugement };
}

/** Un appel au modèle du rédacteur ; null en cas de panne ou de délai. */
async function generer(consigne: string, entree: string, delaiMs: number, config: Record<string, unknown>): Promise<string | null> {
  try {
    const reponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${env.REDACTEUR_MODELE}:generateContent`,
      {
        method: 'POST',
        ...viaLigneGoogle,
        headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY! },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: consigne }] },
          contents: [{ role: 'user', parts: [{ text: entree }] }],
          generationConfig: { maxOutputTokens: 400, thinkingConfig: { thinkingBudget: 0 }, ...config },
        }),
        signal: AbortSignal.timeout(delaiMs),
      },
    );
    if (!reponse.ok) return null;
    const corps = (await reponse.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
    return (corps.candidates?.[0]?.content?.parts ?? []).filter((p) => !p.thought).map((p) => p.text ?? '').join('').trim();
  } catch {
    return null;
  }
}

/**
 * ARTICLE 6 de la constitution, jugé seul : les produits affichés SONT-ils ce
 * que le client demande ? Température 0 : le même verdict à chaque fois (le
 * « lait » donnait des supermarchés un passage, des céréales l'autre).
 */
async function jugerPertinence(r: ARediger, delaiMs: number): Promise<ReadonlySet<string> | null> {
  if (env.REDACTEUR === '0' || !env.GEMINI_API_KEY || !r.message.trim()) return null;
  const produits = (r.composants ?? [])
    .filter((c) => c.type === 'product_carousel' || c.type === 'product_list' || c.type === 'product_card')
    .flatMap((c) => {
      const d = c.data as Record<string, unknown>;
      const items = Array.isArray(d.items) ? d.items as Array<Record<string, unknown>> : [d];
      return items.slice(0, 12).map((i) => ({ id: String(i.id ?? ''), nom: String(i.name ?? '') })).filter((p) => p.id && p.nom);
    });
  if (produits.length === 0) return null;
  const consigne = [
    'Tu juges, produit par produit, si des produits affichés par Tovo (livraison à Niamey) répondent à la demande du client.',
    'Règle (article 6 de la constitution de Tovo) : un produit répond par ce qu’il EST, pas par un ingrédient, un parfum ou une option qu’il contient. Un produit d’une autre nature ne répond pas, même s’il est proche par l’usage, le public ou un mot.',
    '« garder » : les numéros des produits qui SONT ce que le client demande (liste vide si aucun).',
    'Réponds en JSON : {"garder": [numéros]}.',
  ].join('\n');
  const entree = JSON.stringify({
    ...(r.avant ? { dernier_message_de_tovo: r.avant.slice(0, 300) } : {}),
    message_du_client: r.message.slice(0, 500),
    produits_affiches: produits.map((p, i) => `${i + 1}. ${p.nom}`),
  });
  const brut = await generer(consigne, entree, delaiMs, {
    temperature: 0, maxOutputTokens: 80, responseMimeType: 'application/json',
    responseSchema: { type: 'OBJECT', properties: { garder: { type: 'ARRAY', items: { type: 'INTEGER' } } }, required: ['garder'] },
  });
  if (!brut) return null;
  try {
    const v = JSON.parse(brut) as { garder?: unknown };
    if (!Array.isArray(v.garder)) return null;
    return new Set(v.garder.map((n) => produits[Number(n) - 1]?.id).filter((id): id is string => Boolean(id)));
  } catch {
    return null;
  }
}

/** La phrase pour le client, vérifiée ; null en cas de panne (la phrase prévue servira). */
async function appeler(r: ARediger, delaiMs: number): Promise<string | null> {
  const prevue = r.prevue.trim();
  if (env.REDACTEUR === '0' || !env.GEMINI_API_KEY || !r.message.trim()) return null;
  const faits = new Faits();
  faits.ajouter(r.faits);
  faits.ajouter(prevue);
  // Le client : ses mots pour les noms, jamais pour un nombre (verificateur.ts).
  faits.ajouterParole(r.message);
  for (const c of r.composants ?? []) faits.composant(c);

  const entree = JSON.stringify({
    ...(r.avant ? { dernier_message_de_tovo: r.avant.slice(0, 400) } : {}),
    message_du_client: r.message.slice(0, 1000),
    sens_de_la_reponse_prevue: prevue.slice(0, 600),
    faits: r.faits ?? null,
    cartes_affichees: resumeCartes(r.composants ?? []),
  }).slice(0, 6000);

  const texte = await generer(CONSIGNE, entree, delaiMs, { temperature: 0.4 });
  if (texte === null) return null;
  const verifie = verifierTexte(texte, faits);
  // Une phrase inventée retirée : si rien ne reste, la phrase prévue.
  return sansPromesseVide(verifie.texte || prevue, r.composants ?? []);
}

/**
 * La réponse à une PHOTO (19/10). Le chat l'envoyait sans rédacteur, avec une
 * phrase fixe : « Voici les articles qui correspondent à votre photo » — même
 * quand aucun n'était le produit photographié (un lait St Ives → un lait
 * Topicrem). Article 5 : rien d'inventé ; article 6 : un produit répond par ce
 * qu'il EST.
 *
 * Le juge de l'article 6 dit d'abord lesquels SONT le produit de la photo ;
 * le rédacteur écrit ensuite d'après ce verdict, donné comme un fait. Aucun
 * nom de marque dans le code : le verdict vaut pour toutes les photos.
 */
export async function redigerReponsePhoto(r: {
  indication: string;
  resultat: { content?: string; summary: unknown; components: Component[] };
}): Promise<string> {
  const { resultat } = r;
  const resume = (resultat.summary ?? {}) as Record<string, unknown>;
  const lu = String(resume.lu_sur_la_photo ?? '').trim();
  const prevue = resultat.content ?? '';
  const message = `J'ai envoyé la photo d'un produit et je veux exactement ce produit${lu ? ` : ${lu}` : ''}${r.indication ? ` (${r.indication})` : ''}.`;
  if (resultat.components.length === 0 || !lu) {
    return rediger({ message, prevue, faits: resultat.summary, composants: resultat.components });
  }

  const garder = await jugerPertinence({ message, prevue, composants: resultat.components }, 2500);
  const noms = produitsAffiches(resultat.components);
  const identiques = garder ? noms.filter((p) => garder.has(p.id)).map((p) => p.nom) : null;

  // Le sens prévu — et le secours si le rédacteur est en panne — suit le
  // verdict : il ne peut plus annoncer une trouvaille qui n'en est pas une.
  const sens = identiques === null
    ? 'Voici ce qui ressemble le plus à votre photo.'
    : identiques.length > 0
      ? 'Voici le produit de votre photo.'
      : "Ce produit précis n'est pas disponible sur Tovo ; voici des produits proches.";
  const faits = {
    ...resume,
    ...(identiques === null ? {} : {
      produit_de_la_photo_trouve: identiques.length > 0,
      identiques_a_la_photo: identiques,
      autres_produits_affiches: 'proches seulement, pas le produit de la photo',
    }),
  };
  return (await redigerEtJuger({ message, prevue: sens, faits, composants: resultat.components }, 2500, false)).texte;
}

function produitsAffiches(composants: Component[]): Array<{ id: string; nom: string }> {
  return composants
    .filter((c) => c.type === 'product_carousel' || c.type === 'product_list' || c.type === 'product_card')
    .flatMap((c) => {
      const d = c.data as Record<string, unknown>;
      const items = Array.isArray(d.items) ? d.items as Array<Record<string, unknown>> : [d];
      return items.map((i) => ({ id: String(i.id ?? ''), nom: String(i.name ?? '') }));
    })
    .filter((p) => p.id && p.nom);
}
