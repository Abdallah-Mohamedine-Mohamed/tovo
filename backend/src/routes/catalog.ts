import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import {
  categoryGrid,
  envelope,
  optionSelector,
  productCard,
  productCarousel,
  type OptionRow,
  type ProductRow,
} from '../components/builders.js';
import { anonClient } from '../services/supabase.js';

/**
 * Catalogue — le parcours sans IA de la Phase 2.
 *
 * Ces routes renvoient déjà des composants du contrat. En Phase 4,
 * l'orchestrateur produira les mêmes, à partir des mêmes données. Le fil de
 * conversation ne fera pas la différence — c'est ce qui permet de valider le
 * contrat UI avant d'avoir le modèle.
 *
 * Lecture publique : on n'oblige pas à se connecter pour regarder. La RLS
 * limite de toute façon aux boutiques approuvées.
 */

export async function catalogRoutes(app: FastifyInstance): Promise<void> {
  /** Client authentifié si l'appelant l'est, anonyme sinon. */
  function db(request: import('fastify').FastifyRequest) {
    return request.supabase ?? anonClient();
  }

  app.get('/categories', async (request, reply) => {
    const { data, error } = await db(request)
      .from('categories')
      .select('id, name, icon, image_url')
      .is('parent_id', null)
      .eq('is_active', true)
      .order('sort_order');

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send(
      envelope('Que souhaitez-vous commander ?', [categoryGrid(data ?? [])]),
    );
  });

  app.get('/categories/:categoryId/products', async (request, reply) => {
    const params = z.object({ categoryId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { data: categorie } = await db(request)
      .from('categories')
      .select('name')
      .eq('id', params.data.categoryId)
      .maybeSingle();

    const { data, error } = await db(request)
      .from('products')
      .select('id, name, description, image_url, price, is_available, merchant_id, merchants(name)')
      .eq('category_id', params.data.categoryId)
      .eq('is_available', true)
      .limit(8);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const items: ProductRow[] = (data ?? []).map((p) => ({
      id: p.id as string,
      name: p.name as string,
      description: p.description as string | null,
      image_url: p.image_url as string | null,
      price: p.price as number,
      is_available: p.is_available as boolean,
      merchant_id: p.merchant_id as string,
      merchant_name:
        (p.merchants as { name?: string } | null)?.name ?? null,
    }));

    const titre = categorie?.name ? `${categorie.name} près de vous` : 'Résultats';

    if (items.length === 0) {
      return reply.send(
        envelope("Je n'ai rien trouvé dans cette catégorie pour le moment."),
      );
    }

    return reply.send(envelope(titre, [productCarousel(items, titre)]));
  });

  /**
   * Détail d'un produit.
   *
   * S'il porte des options, on renvoie un option_selector et non une carte
   * avec « ajouter » : le contrat l'impose, et la base refuserait l'ajout
   * sans les choix obligatoires de toute façon.
   */
  app.get('/products/:productId', async (request, reply) => {
    const params = z.object({ productId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { data: produit, error } = await db(request)
      .from('products')
      .select('id, name, description, image_url, price, is_available, merchant_id, merchants(name)')
      .eq('id', params.data.productId)
      .maybeSingle();

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    if (!produit) return reply.code(404).send({ error: 'produit introuvable' });

    const product: ProductRow = {
      id: produit.id as string,
      name: produit.name as string,
      description: produit.description as string | null,
      image_url: produit.image_url as string | null,
      price: produit.price as number,
      is_available: produit.is_available as boolean,
      merchant_id: produit.merchant_id as string,
      merchant_name: (produit.merchants as { name?: string } | null)?.name ?? null,
    };

    const { data: options } = await db(request)
      .from('product_options')
      .select(
        'id, name, is_required, min_select, max_select, sort_order, product_option_values(id, name, price_delta, is_available, sort_order)',
      )
      .eq('product_id', product.id)
      .order('sort_order');

    const rows: OptionRow[] = (options ?? []).map((o) => ({
      id: o.id as string,
      name: o.name as string,
      is_required: o.is_required as boolean,
      min_select: o.min_select as number,
      max_select: o.max_select as number,
      values: ((o.product_option_values ?? []) as Array<Record<string, unknown>>)
        .slice()
        .sort((a, b) => Number(a.sort_order ?? 0) - Number(b.sort_order ?? 0))
        .map((v) => ({
          id: v.id as string,
          name: v.name as string,
          price_delta: v.price_delta as number,
          is_available: v.is_available as boolean,
        })),
    }));

    if (rows.length > 0) {
      return reply.send(
        envelope(`${product.name} — quelques précisions :`, [optionSelector(product, rows)]),
      );
    }

    return reply.send(envelope(product.name, [productCard(product)]));
  });
}
