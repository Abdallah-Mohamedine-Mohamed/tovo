import { createHash } from 'node:crypto';
import { env } from '../config/env.js';
import type { LlmToolDefinition } from './llmClient.js';

/**
 * Mise en cache du préfixe stable des conversations.
 *
 * Le prompt système et les treize déclarations d'outils sont identiques à
 * chaque requête : 1 973 jetons envoyés et facturés à chaque tour, alors que
 * la question du client en pèse une dizaine. Gemini sait les garder de son
 * côté et les facturer bien moins cher.
 *
 * POURQUOI EXPLICITE ET NON IMPLICITE. Gemini met en cache tout seul les
 * préfixes assez longs, mais mesure faite, il ne le fait pas ici :
 * `cachedContentTokenCount` reste à zéro sur deux appels identiques — notre
 * préfixe passe sous son seuil. Le cache explicite, lui, accepte nos 1 973
 * jetons.
 *
 * LE PIÈGE DU COÛT. Un cache explicite se paie à l'heure de stockage, qu'on
 * s'en serve ou non. Le maintenir en permanence coûterait plus cher que les
 * économies aux heures creuses — la nuit, personne ne commande à Niamey, et
 * on paierait pour garder au chaud un prompt que personne ne lit. D'où la
 * règle ici : le cache est créé à la première conversation, réutilisé tant
 * qu'il vit, et on le laisse simplement expirer quand plus personne ne
 * parle. Aucune tâche de fond ne le renouvelle.
 *
 * JAMAIS BLOQUANT. Si la création échoue, on renvoie null et l'appelant
 * envoie le prompt en clair comme avant. Une panne du cache ne doit pas
 * empêcher un client de commander son dîner.
 */

const API = 'https://generativelanguage.googleapis.com/v1beta';

/** Durée de vie. Assez longue pour couvrir une soirée de commandes. */
const TTL_SECONDES = 3600;

/**
 * Marge avant expiration.
 *
 * Un cache utilisé à la seconde où il expire fait échouer la requête. On le
 * considère mort une minute avant l'heure.
 */
const MARGE_MS = 60_000;

interface CacheEnCours {
  nom: string;
  expireLe: number;
}

/**
 * Un cache par variante de préfixe, et non un seul emplacement.
 *
 * L'orchestrateur envoie les outils à chaque cycle sauf le dernier, où il
 * les retire pour forcer le modèle à conclure. Deux préfixes coexistent donc.
 * Avec un emplacement unique, ils se chasseraient l'un l'autre : une
 * création à chaque tour, aucun gain, et plus d'appels réseau qu'avant la
 * mise en cache. La table reste minuscule — deux entrées en pratique.
 */
const caches = new Map<string, CacheEnCours>();

/** Créations en vol, pour que dix requêtes simultanées n'en lancent pas dix. */
const enVol = new Map<string, Promise<CacheEnCours | null>>();

/**
 * Empreintes dont la création a échoué, et jusqu'à quand ne pas réessayer.
 *
 * Un préfixe trop court est refusé par Gemini — le nôtre sans les outils ne
 * pèse que 734 jetons. Sans cette mémoire, chaque requête retenterait,
 * ajoutant un aller-retour inutile sur le chemin de la réponse au client.
 */
const echecs = new Map<string, number>();
const REPOS_APRES_ECHEC_MS = 600_000;

/**
 * Identifie le contenu mis en cache.
 *
 * Le modèle, le prompt et les outils en font partie : un déploiement qui
 * change une consigne doit repartir sur un cache neuf, sinon le modèle
 * continuerait d'obéir à l'ancienne version pendant une heure — un décalage
 * invisible et très difficile à diagnostiquer.
 */
function empreinte(system: string, tools: LlmToolDefinition[], modele: string): string {
  return createHash('sha256')
    .update(modele)
    .update(system)
    .update(JSON.stringify(tools))
    .digest('hex')
    .slice(0, 16);
}

function declarations(tools: LlmToolDefinition[]): unknown[] {
  return [
    {
      functionDeclarations: tools.map((t) => ({
        name: t.name,
        description: t.description,
        parameters: t.parameters,
      })),
    },
  ];
}

async function creer(
  system: string,
  tools: LlmToolDefinition[],
  modele: string,
): Promise<CacheEnCours | null> {
  const reponse = await fetch(`${API}/cachedContents`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY! },
    body: JSON.stringify({
      model: `models/${modele}`,
      systemInstruction: { parts: [{ text: system }] },
      ...(tools.length > 0 ? { tools: declarations(tools) } : {}),
      ttl: `${TTL_SECONDES}s`,
    }),
    signal: AbortSignal.timeout(15_000),
  });

  if (!reponse.ok) return null;

  const corps = (await reponse.json()) as { name?: string; expireTime?: string };
  if (!corps.name) return null;

  return {
    nom: corps.name,
    expireLe: corps.expireTime
      ? new Date(corps.expireTime).getTime()
      : Date.now() + TTL_SECONDES * 1000,
  };
}

/**
 * Le cache utilisable pour cette requête, ou null.
 *
 * @returns le nom de ressource à passer dans `cachedContent`, ou null s'il
 *          faut envoyer le prompt et les outils en clair.
 */
export async function cacheDuPrompt(
  system: string,
  tools: LlmToolDefinition[],
  modele: string,
): Promise<string | null> {
  if (!env.GEMINI_API_KEY) return null;

  const cle = empreinte(system, tools, modele);
  const maintenant = Date.now();

  const connu = caches.get(cle);
  if (connu && connu.expireLe - MARGE_MS > maintenant) return connu.nom;

  // Périmé : on l'oublie sans le supprimer chez Gemini, qui s'en charge à
  // l'expiration. Un DELETE ajouterait un aller-retour sur le chemin
  // critique d'une réponse au client.
  if (connu) caches.delete(cle);

  const repos = echecs.get(cle);
  if (repos !== undefined && repos > maintenant) return null;

  let creation = enVol.get(cle);
  if (!creation) {
    creation = creer(system, tools, modele)
      .catch(() => null)
      .finally(() => enVol.delete(cle));
    enVol.set(cle, creation);
  }

  const cree = await creation;
  if (!cree) {
    echecs.set(cle, Date.now() + REPOS_APRES_ECHEC_MS);
    return null;
  }

  // Même marge que pour un cache relu : Gemini peut rendre une expiration
  // plus proche que le TTL demandé. S'en servir à la seconde où il meurt
  // ferait échouer la requête d'un client qui attend sa réponse.
  if (cree.expireLe - MARGE_MS <= Date.now()) return null;

  echecs.delete(cle);
  caches.set(cle, cree);
  return cree.nom;
}

/**
 * Oublie un cache dont Gemini vient de refuser l'usage.
 *
 * Un cache peut disparaître de leur côté avant l'heure annoncée. On le
 * retire de la table plutôt que de rejouer indéfiniment une référence morte.
 */
export function oublierCache(nom: string): void {
  for (const [cle, valeur] of caches) {
    if (valeur.nom === nom) caches.delete(cle);
  }
}

/** Pour les tests : repartir d'un état vierge. */
export function reinitialiserCache(): void {
  caches.clear();
  enVol.clear();
  echecs.clear();
}
