import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { indexProductsByIds } from '../services/indexer.js';
import { decrireImage } from '../services/vision.js';
import { serviceClient } from '../services/supabase.js';

/**
 * Indexation immédiate d'un produit.
 *
 * Le boutiquier écrit sa fiche directement dans Supabase — la RLS l'autorise
 * sur son propre catalogue, et il n'y a aucun calcul serveur à faire. Mais
 * l'indexation, elle, exige la clé Gemini : elle passe donc par ici.
 *
 * Si cet appel échoue, rien n'est perdu : le balayage périodique rattrape le
 * produit dans les cinq minutes. Cette route ne fait que rendre le produit
 * cherchable tout de suite, pendant que le boutiquier est encore devant son
 * écran.
 */
export async function merchantCatalogRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    '/merchant/products/:productId/index',
    { preHandler: app.requireAuth },
    async (request, reply) => {
      const params = z.object({ productId: z.string().uuid() }).safeParse(request.params);
      if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

      // On vérifie la propriété avec le JWT de l'utilisateur : sans ça,
      // n'importe qui pourrait faire indexer — et donc décrire par Vision —
      // le produit d'une autre boutique.
      const { data: produit, error } = await request.supabase!
        .from('products')
        .select('id, image_url, image_description')
        .eq('id', params.data.productId)
        .maybeSingle();

      if (error) {
        const failure = toHttpFailure(error);
        return reply.code(failure.status).send(failure.body);
      }
      if (!produit) return reply.code(404).send({ error: 'produit introuvable' });

      // Une photo vaut souvent mieux que la description écrite : beaucoup de
      // boutiquiers saisissent « Menu 3 ». La description générée enrichit le
      // texte indexé sans qu'ils aient rien à écrire.
      if (produit.image_url && !produit.image_description) {
        const chemin = cheminStorage(produit.image_url as string);
        if (chemin) {
          try {
            const description = await decrireImage(chemin, 'products');
            await serviceClient()
              .from('products')
              .update({ image_description: description })
              .eq('id', produit.id);
          } catch (cause) {
            // La description est un bonus. Son absence ne doit pas empêcher
            // l'indexation du nom et de la description écrite.
            request.log.warn({ cause }, 'description automatique impossible');
          }
        }
      }

      const resultat = await indexProductsByIds([params.data.productId]);

      return reply.send({
        indexed: resultat.indexed,
        failed: resultat.failed,
      });
    },
  );
}

/**
 * Extrait le chemin Storage d'une URL publique.
 *
 * Supabase sert les fichiers publics sous
 * `.../storage/v1/object/public/products/{chemin}`.
 */
function cheminStorage(url: string): string | null {
  const marqueur = '/object/public/products/';
  const index = url.indexOf(marqueur);
  if (index === -1) return null;
  return decodeURIComponent(url.slice(index + marqueur.length));
}
