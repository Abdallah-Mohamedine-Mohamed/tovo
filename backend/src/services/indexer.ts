import { serviceClient } from './supabase.js';
import { embed, texteIndexable } from './embeddings.js';
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

async function indexerChacun(produits: ProduitAIndexer[]): Promise<IndexOutcome> {
  const db = serviceClient();
  let indexed = 0;
  let failed = 0;

  for (const produit of produits) {
    const texte = texteIndexable(produit);

    try {
      const vecteur = await embed(texte, 'document');

      await db
        .from('products')
        .update({
          embedding: vecteur,
          embedded_at: new Date().toISOString(),
          // On conserve le texte indexé : sans lui, impossible de savoir
          // pourquoi un produit ne remonte pas dans une recherche.
          embedding_source: texte.slice(0, 500),
        })
        .eq('id', produit.id);

      indexed++;
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
