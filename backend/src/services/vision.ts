import { env } from '../config/env.js';
import { serviceClient } from './supabase.js';

/**
 * Description d'image par Gemini Vision.
 *
 * N'est PLUS utilisée pour la recherche par photo : celle-ci compare
 * désormais les vecteurs d'image directement, sans passer par une phrase
 * — voir embedImage(). Réduire une image à une phrase perdait trop, et se
 * trompait sur les plats dont le nom dépend du pays.
 *
 * Reste utile à l'INDEXATION : beaucoup de boutiquiers écrivent « Menu 3 »
 * en guise de description. Une description générée à partir de la photo
 * enrichit alors le texte indexé du produit.
 *
 * L'image ne transite JAMAIS par le contexte du modèle d'orchestration. Elle
 * est téléversée dans Storage par Flutter, lue ici avec la service_role, et
 * seule sa description revient. Faire passer les octets en base64 dans un
 * argument d'outil les inscrirait dans l'historique de conversation, à
 * chaque tour, pour toujours.
 */

// Le même modèle que l'orchestrateur, et depuis la même variable : un
// modèle épinglé à deux endroits finit toujours par diverger, et l'un des
// deux tombe en silence le jour où Google en retire un.
const MODELE = env.GEMINI_MODEL;

/**
 * Des MOTS-CLÉS, et surtout pas une description.
 *
 * La consigne demandait « une seule phrase factuelle et précise ». Le modèle
 * la rendait fidèlement — « Une souris d'ordinateur sans fil noire posée sur
 * un bureau » — et la recherche ne trouvait rien.
 *
 * Mesuré sur le catalogue réel : « souris » ramène 2 articles, « souris sans
 * fil » en ramène 5, la phrase complète en ramène ZÉRO. Sans vecteur, la
 * recherche compare des trigrammes ; entre une phrase de dix mots et un nom
 * de produit de trois, la similarité tombe sous le plancher de 0,70 et tout
 * est écarté. Plus la description était riche, moins elle trouvait.
 *
 * On demande donc ce qu'un client taperait lui-même dans une barre de
 * recherche, ce qui est exactement ce que le moteur sait traiter.
 */
const CONSIGNE = `Donne les mots-clés qui permettraient de retrouver ce produit
dans le catalogue d'une boutique, comme si tu les tapais dans une barre de
recherche.

Trois à cinq mots maximum, séparés par des espaces. Pas de phrase, pas de
verbe, pas d'article.

Commence par le nom de l'objet ou du plat. Ajoute ensuite, seulement si
c'est lisible sur l'image et utile pour le distinguer : la marque, puis une
caractéristique déterminante (sans fil, 1,5 L, rouge).

Ignore l'arrière-plan, les personnes, le lieu, et tout détail qui ne servirait
pas à le chercher. N'invente aucune marque.

Exemples de bonnes réponses :
souris sans fil
clavier Logitech
poulet braisé
eau minérale 1,5 L`;

export class VisionUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'VisionUnavailableError';
  }
}

export const visionEnabled = Boolean(env.GEMINI_API_KEY);

/**
 * Décrit l'image déposée dans le bucket `search-images`.
 *
 * @param path   chemin Storage, de la forme `{user_id}/{uuid}.jpg`
 * @param bucket `search-images` pour une recherche client, `products`
 *               pour enrichir une fiche produit à l'indexation
 */
export async function decrireImage(
  path: string,
  bucket: 'search-images' | 'products' = 'search-images',
): Promise<string> {
  if (!env.GEMINI_API_KEY) {
    throw new VisionUnavailableError('GEMINI_API_KEY absente');
  }

  // Le chemin vient d'une interaction utilisateur : on vérifie qu'il reste
  // dans le bucket prévu. Sans ça, un client pourrait faire décrire par le
  // modèle une preuve de livraison ou une image d'un autre bucket.
  if (path.includes('..') || path.startsWith('/')) {
    throw new VisionUnavailableError('chemin invalide');
  }

  const { data, error } = await serviceClient()
    .storage.from(bucket)
    .download(path);

  if (error || !data) {
    throw new VisionUnavailableError('image introuvable');
  }

  const octets = Buffer.from(await data.arrayBuffer());
  if (octets.byteLength > 4 * 1024 * 1024) {
    throw new VisionUnavailableError('image trop lourde');
  }

  const controleur = new AbortController();
  const delai = setTimeout(() => controleur.abort(), 20_000);

  try {
    const reponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODELE}:generateContent`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': env.GEMINI_API_KEY,
        },
        body: JSON.stringify({
          contents: [
            {
              role: 'user',
              parts: [
                { text: CONSIGNE },
                {
                  inlineData: {
                    mimeType: data.type || 'image/jpeg',
                    data: octets.toString('base64'),
                  },
                },
              ],
            },
          ],
          generationConfig: {
            temperature: 0.1,
            // Large, alors que la réponse tient en cinq mots.
            //
            // Les tokens de réflexion se déduisent de ce quota, et il n'y a
            // plus moyen de les couper : `thinkingConfig.thinkingBudget = 0`
            // est REFUSÉ par gemini-3.5-flash-lite — un 400 sur toutes les
            // requêtes, donc plus une seule photo décrite. Vérifié : la même
            // requête sans ce champ passe en 200.
            //
            // On donne donc de la marge au lieu d'interdire : le modèle
            // réfléchit un peu et il lui reste de quoi répondre.
            maxOutputTokens: 400,
          },
        }),
        signal: controleur.signal,
      },
    );

    if (!reponse.ok) {
      // Le corps, et pas seulement le code. Un 400 nu ne dit ni quel champ
      // est en cause, ni si le modèle existe — et c'est précisément ce qu'on
      // cherche quand la recherche par photo cesse de fonctionner.
      const detail = (await reponse.text().catch(() => '')).replace(/\s+/g, ' ').slice(0, 300);
      throw new VisionUnavailableError(
        `Vision a répondu ${reponse.status}${detail ? ` — ${detail}` : ''}`,
      );
    }

    const json = (await reponse.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
    };

    const description = (json.candidates?.[0]?.content?.parts ?? [])
      .map((p) => p.text ?? '')
      .join('')
      .trim();

    if (!description) {
      throw new VisionUnavailableError("Aucune description n'a pu être produite");
    }

    return description.slice(0, 400);
  } catch (cause) {
    if (cause instanceof VisionUnavailableError) throw cause;
    if (cause instanceof Error && cause.name === 'AbortError') {
      throw new VisionUnavailableError("L'analyse de l'image a pris trop de temps");
    }
    throw new VisionUnavailableError(
      cause instanceof Error ? cause.message : 'Analyse impossible',
    );
  } finally {
    clearTimeout(delai);
  }
}
