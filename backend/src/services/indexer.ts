import { serviceClient } from './supabase.js';
import { embed, embedImage, texteIndexable } from './embeddings.js';
import { registerProcessor, startWorker, getQueue } from './queue.js';

/**
 * Indexation des produits.
 *
 * Un produit sans embedding est invisible à la recherche sémantique. Un
 * produit dont le nom a changé mais dont l'embedding date d'avant répond sur
 * l'ancien texte — silencieusement, ce qui est pire.
 *
 * `products_to_embed()` remonte les deux cas : jamais indexé, ou indexé
 * avant la dernière modification. Le balayage tourne en tâche de fond ; il
 * n'y a rien à déclencher à la main quand un boutiquier corrige une fiche.
 *
 * Job sans utilisateur, donc `serviceClient()` est légitime ici.
 */

export const INDEX_QUEUE = 'product-index';

interface ProduitAIndexer {
  id: string;
  name: string;
  description: string | null;
  image_description: string | null;
  tags: string[] | null;
}

export interface IndexOutcome {
  examined: number;
  indexed: number;
  failed: number;
}

export async function indexProducts(limite = 50): Promise<IndexOutcome> {
  const db = serviceClient();

  const { data, error } = await db.rpc('products_to_embed', { limite });
  if (error) throw error;

  return indexerChacun((data ?? []) as ProduitAIndexer[]);
}

/**
 * Tronque sans couper un caractère en deux.
 *
 * `slice` compte en unités UTF-16, et un emoji en occupe deux. Couper entre
 * les deux laisse une moitié orpheline : `JSON.stringify` l'accepte, mais le
 * corps de la requête encodé en UTF-8 devient invalide et PostgREST la
 * refuse avec « Empty or invalid json ».
 *
 * Vu en migration sur une description finissant par 🍎🥭✨ : le produit
 * n'était jamais indexé, donc jamais trouvable, et l'indexeur le reprenait à
 * chaque passage. Un boutiquier met un emoji dans sa description sans y
 * penser — il suffit qu'il tombe au mauvais endroit.
 */
export function tronquer(texte: string, maximum: number): string {
  if (texte.length <= maximum) return texte;

  const coupe = texte.slice(0, maximum);
  const dernier = coupe.charCodeAt(maximum - 1);
  // Moitié haute d'une paire de substitution : sa moitié basse est tombée.
  return dernier >= 0xd800 && dernier <= 0xdbff ? coupe.slice(0, -1) : coupe;
}

/**
 * Vectorise la photo du produit, si elle ne l'a jamais été.
 *
 * SÉPARÉ DU TEXTE, ET DÉLIBÉRÉMENT SANS CONSÉQUENCE. Une image inaccessible
 * ou un refus de l'API ne doit pas faire compter le produit comme non
 * indexé : son texte, lui, est bien en place et le rend cherchable. Traiter
 * les deux comme un seul échec ferait reprendre le produit à chaque passage
 * pour une photo qui ne reviendra jamais.
 *
 * La date est écrite même en cas d'échec, pour la même raison : sans elle,
 * une URL morte serait retentée indéfiniment.
 */
async function vectoriserLaPhoto(id: string, url: string): Promise<void> {
  const db = serviceClient();
  try {
    const reponse = await fetch(url, { signal: AbortSignal.timeout(30_000) });
    if (!reponse.ok) throw new Error(`HTTP ${reponse.status}`);

    const octets = Buffer.from(await reponse.arrayBuffer());
    if (octets.byteLength > 8 * 1024 * 1024) throw new Error('image trop lourde');

    const vecteur = await embedImage(
      octets,
      reponse.headers.get('content-type') ?? 'image/jpeg',
    );

    await db
      .from('products')
      .update({ image_embedding: vecteur, image_embedded_at: new Date().toISOString() })
      .eq('id', id);
  } catch (cause) {
    // eslint-disable-next-line no-console
    console.error(
      `[indexer] photo de ${id} non vectorisée :`,
      cause instanceof Error ? cause.message : cause,
    );
    await db
      .from('products')
      .update({ image_embedded_at: new Date().toISOString() })
      .eq('id', id);
  }
}

async function indexerChacun(produits: ProduitAIndexer[]): Promise<IndexOutcome> {
  const db = serviceClient();
  let indexed = 0;
  let failed = 0;

  // Une seule requete pour tout le lot : savoir quelles photos restent a
  // vectoriser ne vaut pas cinquante allers-retours.
  const { data: photos } = await db
    .from("products")
    .select("id, image_url")
    .in("id", produits.map((p) => p.id))
    .not("image_url", "is", null)
    .is("image_embedded_at", null);

  const aVectoriser = new Map(
    ((photos ?? []) as Array<{ id: string; image_url: string }>).map((p) => [
      p.id,
      p.image_url,
    ]),
  );

  for (const produit of produits) {
    const texte = texteIndexable(produit);

    try {
      const vecteur = await embed(texte, 'document');

      const { error: erreurEcriture } = await db
        .from('products')
        .update({
          embedding: vecteur,
          embedded_at: new Date().toISOString(),
          // On conserve le texte indexé : sans lui, impossible de savoir
          // pourquoi un produit ne remonte pas dans une recherche.
          embedding_source: tronquer(texte, 500),
        })
        .eq('id', produit.id);

      // Sans ce contrôle, un échec d'écriture se compte comme un succès : le
      // produit reste invisible à la recherche, l'indexeur le reprend à
      // chaque passage, et les compteurs affichent zéro échec.
      if (erreurEcriture) throw erreurEcriture;

      indexed++;

      // Apres le texte, et hors du compteur : la photo est un complement,
      // son echec ne rend pas le produit introuvable.
      const photo = aVectoriser.get(produit.id);
      if (photo) await vectoriserLaPhoto(produit.id, photo);
    } catch (cause) {
      // Un produit qui échoue ne doit pas bloquer les autres : il sera
      // repris au prochain passage, puisqu'il reste sans embedding.
      failed++;
      // eslint-disable-next-line no-console
      console.error(
        `[indexer] ${produit.id} non indexé :`,
        cause instanceof Error ? cause.message : cause,
      );
    }
  }

  return { examined: produits.length, indexed, failed };
}

/**
 * Indexe des produits précis, sans attendre le balayage périodique.
 *
 * Utilisé quand un boutiquier enregistre une fiche : il ne devrait pas
 * attendre cinq minutes que son plat devienne cherchable.
 */
export async function indexProductsByIds(ids: string[]): Promise<IndexOutcome> {
  if (ids.length === 0) return { examined: 0, indexed: 0, failed: 0 };

  const db = serviceClient();
  const { data, error } = await db
    .from('products')
    .select('id, name, description, image_description, tags')
    .in('id', ids);

  if (error) throw error;
  return indexerChacun((data ?? []) as ProduitAIndexer[]);
}

const processor = async (): Promise<IndexOutcome> => indexProducts();

export function registerIndexProcessor(): void {
  registerProcessor(INDEX_QUEUE, processor);
}

export async function startIndexer(): Promise<void> {
  startWorker(INDEX_QUEUE, processor);

  const queue = getQueue(INDEX_QUEUE);
  if (!queue) return;

  // Toutes les 5 minutes : un produit créé par un boutiquier devient
  // cherchable dans les minutes qui suivent, sans qu'il ait à attendre ni
  // à comprendre ce qu'est un embedding.
  await queue.upsertJobScheduler(
    'index-recurrent',
    { every: 300_000 },
    { name: INDEX_QUEUE, data: {}, opts: { removeOnComplete: 20, removeOnFail: 50 } },
  );
}
