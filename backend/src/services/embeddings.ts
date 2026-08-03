import { env } from '../config/env.js';

/**
 * Génération d'embeddings.
 *
 * Un embedding est un vecteur de 1536 nombres qui représente le sens d'un
 * texte. Deux textes proches produisent deux vecteurs proches, ce qui permet
 * de retrouver « tuo zaafi » quand l'utilisateur écrit « pâte de mil ».
 *
 * La dimension 1536 n'est pas un réglage : elle est inscrite dans le schéma
 * (`vector(1536)`) et dans l'index HNSW. `gemini-embedding-001` sort
 * nativement en 3072 et accepte une troncature à 1536 — vérifié contre l'API.
 *
 * ATTENTION AU CHANGEMENT DE MODÈLE. Deux modèles produisent des espaces
 * vectoriels incomparables, même à dimension égale. Changer de fournisseur
 * impose de réindexer TOUT le catalogue ; mélanger les deux donne une
 * recherche silencieusement fausse. C'est la vraie raison de choisir une
 * fois et de s'y tenir.
 */

export const EMBEDDING_DIMENSIONS = 1536;
// Modèle MULTIMODAL : texte et images atterrissent dans le même espace
// vectoriel. C'est ce qui permet de chercher un produit à partir d'une
// photo sans passer par une description écrite — voir embedImage().
const MODELE = 'gemini-embedding-2';

/**
 * Le type de tâche oriente le vecteur produit.
 *
 * Un même texte n'est pas encodé de la même façon selon qu'il est indexé ou
 * qu'il sert de requête. Utiliser le bon des deux améliore nettement le
 * rappel, et ne coûte rien.
 */
export type EmbeddingTask = 'document' | 'query';

const TASK_TYPES: Record<EmbeddingTask, string> = {
  document: 'RETRIEVAL_DOCUMENT',
  query: 'RETRIEVAL_QUERY',
};

export class EmbeddingUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'EmbeddingUnavailableError';
  }
}

export const embeddingsEnabled = Boolean(env.GEMINI_API_KEY);

/**
 * Un réessai, une seule fois.
 *
 * Les `fetch failed` transitoires sont fréquents sur une liaison longue.
 * Réessayer indéfiniment masquerait une panne réelle ; ne jamais réessayer
 * fait échouer une indexation pour un hoquet réseau.
 */
export async function embed(
  texte: string,
  task: EmbeddingTask = 'query',
): Promise<number[]> {
  try {
    return await embedUneFois(texte, task);
  } catch (cause) {
    // Le délai dépassé est le cas le PLUS transitoire : ne pas le réessayer
    // faisait échouer une indexation entière pour un hoquet de deux secondes.
    if (
      cause instanceof EmbeddingUnavailableError &&
      /fetch failed|réseau|ECONN|Délai dépassé/i.test(cause.message)
    ) {
      await new Promise((r) => setTimeout(r, 800));
      return embedUneFois(texte, task);
    }
    throw cause;
  }
}

async function embedUneFois(
  texte: string,
  task: EmbeddingTask,
): Promise<number[]> {
  if (!env.GEMINI_API_KEY) {
    throw new EmbeddingUnavailableError('GEMINI_API_KEY absente');
  }

  const propre = texte.trim().slice(0, 8000);
  if (propre.length === 0) {
    throw new EmbeddingUnavailableError('texte vide');
  }

  const controleur = new AbortController();
  const delai = setTimeout(() => controleur.abort(), 20_000);

  try {
    const reponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODELE}:embedContent`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': env.GEMINI_API_KEY,
        },
        body: JSON.stringify({
          model: `models/${MODELE}`,
          content: { parts: [{ text: propre }] },
          taskType: TASK_TYPES[task],
          outputDimensionality: EMBEDDING_DIMENSIONS,
        }),
        signal: controleur.signal,
      },
    );

    if (!reponse.ok) {
      const detail = await reponse.text().catch(() => '');
      throw new EmbeddingUnavailableError(
        `Embedding refusé (HTTP ${reponse.status})${detail ? ` : ${detail.slice(0, 200)}` : ''}`,
      );
    }

    const json = (await reponse.json()) as { embedding?: { values?: number[] } };
    const vecteur = json.embedding?.values;

    if (!vecteur || vecteur.length !== EMBEDDING_DIMENSIONS) {
      // Une dimension inattendue produirait une erreur Postgres obscure au
      // moment de l'insertion. Mieux vaut échouer ici, avec le vrai motif.
      throw new EmbeddingUnavailableError(
        `Dimension inattendue : ${vecteur?.length ?? 0} au lieu de ${EMBEDDING_DIMENSIONS}`,
      );
    }

    return normaliser(vecteur);
  } catch (cause) {
    if (cause instanceof EmbeddingUnavailableError) throw cause;
    if (cause instanceof Error && cause.name === 'AbortError') {
      throw new EmbeddingUnavailableError("Délai dépassé à la génération de l'embedding");
    }
    throw new EmbeddingUnavailableError(
      cause instanceof Error ? cause.message : 'Service indisponible',
    );
  } finally {
    clearTimeout(delai);
  }
}

/**
 * Embedding d'une image, dans le MÊME espace que les textes.
 *
 * C'est ce qui supprime le goulot d'étranglement de la recherche par photo.
 * Auparavant : image → phrase → vecteur. La phrase était irréversible — le
 * modèle de vision nommait le plat « chawarma » là où l'utilisateur voyait
 * un tacos, et la recherche cherchait du chawarma. Un tacos français et un
 * chawarma partagent leur pain ; les nommer est culturellement ambigu, et
 * aucun modèle ne tranchera de façon fiable.
 *
 * En comparant directement l'image aux produits, on ne dépend plus d'aucun
 * nom.
 */
export async function embedImage(
  octets: Buffer,
  mimeType = 'image/jpeg',
): Promise<number[]> {
  if (!env.GEMINI_API_KEY) {
    throw new EmbeddingUnavailableError('GEMINI_API_KEY absente');
  }

  const controleur = new AbortController();
  const delai = setTimeout(() => controleur.abort(), 20_000);

  try {
    const reponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODELE}:embedContent`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': env.GEMINI_API_KEY,
        },
        body: JSON.stringify({
          model: `models/${MODELE}`,
          content: { parts: [{ inlineData: { mimeType, data: octets.toString('base64') } }] },
          outputDimensionality: EMBEDDING_DIMENSIONS,
        }),
        signal: controleur.signal,
      },
    );

    if (!reponse.ok) {
      const detail = await reponse.text().catch(() => '');
      throw new EmbeddingUnavailableError(
        `Embedding d'image refusé (HTTP ${reponse.status})${detail ? ` : ${detail.slice(0, 200)}` : ''}`,
      );
    }

    const json = (await reponse.json()) as { embedding?: { values?: number[] } };
    const vecteur = json.embedding?.values;

    if (!vecteur || vecteur.length !== EMBEDDING_DIMENSIONS) {
      throw new EmbeddingUnavailableError(
        `Dimension inattendue : ${vecteur?.length ?? 0}`,
      );
    }

    return normaliser(vecteur);
  } catch (cause) {
    if (cause instanceof EmbeddingUnavailableError) throw cause;
    if (cause instanceof Error && cause.name === 'AbortError') {
      throw new EmbeddingUnavailableError("Délai dépassé à l'analyse de l'image");
    }
    throw new EmbeddingUnavailableError(
      cause instanceof Error ? cause.message : 'Service indisponible',
    );
  } finally {
    clearTimeout(delai);
  }
}

/**
 * Ramène le vecteur à une norme de 1.
 *
 * La distance cosinus utilisée par pgvector normalise déjà en interne, donc
 * ce n'est pas indispensable aujourd'hui. Ça le devient si l'on passe un
 * jour au produit scalaire, et Google le recommande explicitement pour les
 * vecteurs tronqués. Le coût est nul.
 */
function normaliser(vecteur: number[]): number[] {
  const norme = Math.sqrt(vecteur.reduce((acc, v) => acc + v * v, 0));
  if (norme === 0) return vecteur;
  return vecteur.map((v) => v / norme);
}

/**
 * Texte à indexer pour un produit.
 *
 * On concatène nom, description et description d'image. Les modèles
 * d'embedding n'ont quasiment jamais vu « tuo zaafi » ou « dèguè » : ce sont
 * des mots rares sur le web. C'est la description qui ancre le sens — d'où
 * l'importance d'inciter les boutiquiers à en écrire de vraies.
 */
export function texteIndexable(produit: {
  name: string;
  description?: string | null;
  image_description?: string | null;
  tags?: string[] | null;
}): string {
  return [
    produit.name,
    produit.description,
    produit.image_description,
    produit.tags?.join(' '),
  ]
    .filter((p): p is string => Boolean(p && p.trim()))
    .join('. ');
}
