import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import {
  categoryGrid,
  merchantCard,
  envelope,
  optionSelector,
  productCard,
  productCarousel,
  type OptionRow,
  type ProductRow,
} from '../components/builders.js';
import { anonClient } from '../services/supabase.js';
import { embed, embeddingsEnabled } from '../services/embeddings.js';

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

  /**
   * Les catégories qu'on peut réellement parcourir.
   *
   * On ne liste plus toutes les racines actives : dix d'entre elles ne
   * mènent à aucun produit — sept datent des essais d'avant la migration,
   * et Coursier, Tovo Shop et Gaz n'ont jamais été garnies. Un client qui
   * en ouvre trois d'affilée et lit trois fois « je n'ai rien trouvé »
   * conclut que l'application est vide, et il a raison de le croire.
   */
  app.get('/categories', async (request, reply) => {
    const { data, error } = await db(request).rpc('browsable_categories');

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send(
      envelope('Que souhaitez-vous commander ?', [categoryGrid(data ?? [])]),
    );
  });

  /**
   * Recherche directe, sans passer par le modèle.
   *
   * « tacos » est un mot-clé sans ambiguïté : le faire interpréter coûtait
   * 3,5 secondes et un appel Gemini facturé pour une requête que la base
   * traite en 200 ms. Le modèle reste utile pour « quelque chose de léger
   * pour ce soir » — l'app n'y revient que si cette route ne trouve rien.
   *
   * Même moteur que l'assistant : vecteur et trigramme fusionnés. Seul le
   * chemin change, pas la qualité du classement.
   */
  app.get('/search', async (request, reply) => {
    const query = z
      .object({
        q: z.string().min(2).max(120),
        lat: z.coerce.number().min(-90).max(90).optional(),
        lng: z.coerce.number().min(-180).max(180).optional(),
      })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    // Sans clé Gemini, on garde la moitié lexicale : une recherche
    // approximative vaut mieux qu'une page blanche.
    const vecteur = embeddingsEnabled
      ? await embed(query.data.q, 'query').catch(() => null)
      : null;

    const { data, error } = await db(request).rpc('search_products', {
      query_text: query.data.q,
      query_embedding: vecteur ? JSON.stringify(vecteur) : null,
      origin_lat: query.data.lat ?? null,
      origin_lng: query.data.lng ?? null,
      radius_m: null,
      filter_category: null,
      match_count: null,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const items: ProductRow[] = ((data ?? []) as Record<string, unknown>[]).map((p) => ({
      id: p['id'] as string,
      name: p['name'] as string,
      description: (p['description'] as string | null) ?? null,
      image_url: (p['image_url'] as string | null) ?? null,
      price: p['price'] as number,
      is_available: p['is_available'] as boolean,
      merchant_id: p['merchant_id'] as string,
      merchant_name: (p['merchant_name'] as string | null) ?? null,
      merchant_open: (p['merchant_open'] as boolean | null) ?? null,
      distance_m: (p['distance_m'] as number | null) ?? null,
    }));

    // Zéro résultat : on le dit sans composant. L'app enchaîne alors sur
    // l'assistant, qui saura peut-être interpréter ce que la base n'a pas
    // reconnu.
    if (items.length === 0) {
      return reply.send(envelope(`Rien trouvé pour « ${query.data.q} ».`));
    }

    const fermees = items.filter((i) => i.merchant_open === false).length;
    const message = fermees === items.length
      ? `${items.length} résultat${items.length > 1 ? 's' : ''}, mais tout est fermé en ce moment.`
      : `Voici ce que j'ai trouvé pour « ${query.data.q} ».`;

    return reply.send(envelope(message, [productCarousel(items, query.data.q)]));
  });

  /**
   * Les boutiques d'une catégorie.
   *
   * Chez 6ammart un module regroupe des BOUTIQUES — Restaurants en compte
   * 31 — et la migration a fait de ces modules les catégories racines.
   * Toucher « Restaurants » déversait jusqu'ici les plats de trente
   * enseignes mélangées : ce n'est pas ainsi qu'on choisit à manger, et un
   * « 1/2 poulet » sorti de son restaurant n'aide personne.
   *
   * Le parcours est donc : catégorie → boutiques → produits.
   */
  app.get('/categories/:categoryId/merchants', async (request, reply) => {
    const params = z.object({ categoryId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const query = z
      .object({
        lat: z.coerce.number().min(-90).max(90).optional(),
        lng: z.coerce.number().min(-180).max(180).optional(),
      })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    const { data: categorie } = await db(request)
      .from('categories')
      .select('name')
      .eq('id', params.data.categoryId)
      .maybeSingle();

    const { data, error } = await db(request).rpc('category_merchants', {
      p_category_id: params.data.categoryId,
      p_lat: query.data.lat ?? null,
      p_lng: query.data.lng ?? null,
      p_limite: 20,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const boutiques = ((data ?? []) as Record<string, unknown>[]).map((m) => ({
      id: m['id'] as string,
      name: m['name'] as string,
      description: (m['description'] as string | null) ?? null,
      logo_url: (m['logo_url'] as string | null) ?? null,
      address_hint: (m['address_hint'] as string | null) ?? '',
      is_open: (m['is_open'] as boolean) ?? false,
      rating: Number(m['rating'] ?? 5),
      prep_time_min: (m['prep_time_min'] as number) ?? 20,
      distance_m: (m['distance_m'] as number | null) ?? null,
    }));

    const nom = (categorie?.name as string | null) ?? 'Cette catégorie';

    if (boutiques.length === 0) {
      return reply.send(envelope(`Aucune boutique dans ${nom} pour le moment.`));
    }

    const ouvertes = boutiques.filter((b) => b.is_open).length;
    const message = ouvertes > 0
      ? `${nom} — ${ouvertes} ouverte${ouvertes > 1 ? 's' : ''} en ce moment`
      : `${nom} — tout est fermé pour l'instant`;

    return reply.send(envelope(message, boutiques.map(merchantCard)));
  });

  app.get('/categories/:categoryId/products', async (request, reply) => {
    const params = z.object({ categoryId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { data: categorie } = await db(request)
      .from('categories')
      .select('name')
      .eq('id', params.data.categoryId)
      .maybeSingle();

    // Les ENFANTS comptent autant que la catégorie elle-même : la migration
    // a fait des modules 6ammart les racines et de leurs 151 catégories les
    // enfants, si bien qu'aucun produit n'est attaché à une racine.
    // « Restaurants » a 0 produit direct et 1 262 par ses enfants.
    const { data, error } = await db(request).rpc('category_products', {
      p_category_id: params.data.categoryId,
      p_limite: 12,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const items: ProductRow[] = ((data ?? []) as Record<string, unknown>[]).map((p) => ({
      id: p['id'] as string,
      name: p['name'] as string,
      description: (p['description'] as string | null) ?? null,
      image_url: (p['image_url'] as string | null) ?? null,
      price: p['price'] as number,
      is_available: p['is_available'] as boolean,
      merchant_id: p['merchant_id'] as string,
      merchant_name: (p['merchant_name'] as string | null) ?? null,
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
   * Le catalogue d'une boutique.
   *
   * Ouvrir une boutique est un geste DÉTERMINISTE : on sait exactement quoi
   * afficher. Ça passait par l'assistant, qui recevait « Montre-moi ce que
   * propose la boutique {uuid} » sans aucun outil capable de le faire — il
   * tentait une recherche textuelle sur l'identifiant et répondait « je n'ai
   * rien trouvé ». Un aller-retour au modèle, payé, pour une réponse fausse.
   */
  app.get('/merchants/:merchantId/products', async (request, reply) => {
    const params = z.object({ merchantId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const query = z
      .object({ limit: z.coerce.number().int().min(1).max(30).default(12) })
      .safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });

    const { data: boutique } = await db(request)
      .from('merchants')
      .select('name, is_open')
      .eq('id', params.data.merchantId)
      .maybeSingle();

    // La RLS masque les boutiques non approuvées : une réponse vide ici veut
    // dire « pas pour vous » autant que « inexistante », et on ne distingue
    // pas les deux — la différence renseignerait un curieux.
    if (!boutique) {
      return reply.code(404).send({ error: 'boutique introuvable' });
    }

    const { data, error } = await db(request)
      .from('products')
      .select('id, name, description, image_url, price, is_available, merchant_id, merchants(name)')
      .eq('merchant_id', params.data.merchantId)
      .eq('is_available', true)
      .order('name')
      .limit(query.data.limit);

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
      merchant_name: (p.merchants as { name?: string } | null)?.name ?? null,
    }));

    const nom = (boutique.name as string | null) ?? 'Cette boutique';

    if (items.length === 0) {
      return reply.send(
        envelope(`${nom} n'a rien de disponible en ce moment.`),
      );
    }

    // Le fait qu'une boutique soit fermée se dit ici, pas à la commande :
    // découvrir au moment de payer que personne ne prépare est bien pire.
    const titre = boutique.is_open === false ? `${nom} — fermée` : nom;

    return reply.send(envelope(titre, [productCarousel(items, nom)]));
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
