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
  quickReplies,
  type OptionRow,
  type ProductRow,
} from '../components/builders.js';
import { anonClient } from '../services/supabase.js';
import { cataloguePage, resolveCatalogueIntent, merchantIntentAnswer, searchAnswer, merchantMenu } from '../services/catalogue.js';
import { demandeDeRepas } from '../ai/intents.js';

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

/**
 * Ce qu'on dit au-dessus des résultats, sans déranger le modèle.
 *
 * L'ancienne phrase renvoyait au client ses propres mots : « Voici ce que
 * j'ai trouvé pour "tacos boulettes" ». C'est le réflexe d'un moteur de
 * recherche — ça ne lui apprend rien, et ça montre qu'on n'a pas regardé ce
 * qu'on lui rend.
 *
 * On dispose pourtant de tout ce qu'il faut pour dire quelque chose d'utile :
 * combien d'articles, chez combien de boutiques, à quelle distance, et
 * combien sont fermées. Aucun appel au modèle, aucune latence.
 */
/**
 * « Comme la dernière fois ? »
 *
 * L'accueil montrait neuf tuiles de catégories à quelqu'un qui, la plupart
 * du temps, veut reprendre ce qu'il a déjà pris. Le parcours complet —
 * catégorie, boutique, produit, options, panier — pour un plat qu'il connaît
 * par cœur.
 *
 * Réduire l'effort vaut mieux ici que susciter l'envie : le besoin de manger
 * revient de lui-même, il n'a pas à être fabriqué. Ce qui se gagne, c'est le
 * nombre de gestes entre la faim et la commande.
 *
 * Rend une chaîne vide quand il n'y a rien à proposer — client non connecté,
 * ou aucune commande livrée. L'accueil reste alors tel qu'il était.
 */
async function commandePrecedente(
  request: import('fastify').FastifyRequest,
): Promise<{ ligne: string; composant: ReturnType<typeof quickReplies> } | null> {
  if (!request.supabase) return null;

  const { data } = await request.supabase.rpc('last_delivered_order');
  const c = data as {
    order_id?: string;
    total?: number;
    merchant_name?: string | null;
    articles?: Array<{ nom: string; quantite: number }>;
  } | null;

  if (!c?.order_id) return null;

  const articles = c.articles ?? [];
  if (articles.length === 0) return null;

  // Le premier article nomme la commande, le reste se compte. « Tacos XL et
  // 2 autres » se lit d'un coup d'œil ; la liste complète ne se lit pas.
  const titre =
    articles.length === 1
      ? articles[0]!.nom
      : `${articles[0]!.nom} et ${articles.length - 1} autre${articles.length > 2 ? 's' : ''}`;

  const chezQui = c.merchant_name ? ` chez ${c.merchant_name}` : '';

  return {
    ligne: `La dernière fois : ${titre}${chezQui}.`,
    composant: quickReplies([
      { label: `Reprendre — ${c.total} F`, value: `recommander:${c.order_id}` },
    ]),
  };
}

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

    // PAS DE TITRE DE GRILLE, et une phrase seulement si elle apprend
    // quelque chose.
    //
    // L'accueil posait la même question trois fois : le salut de
    // l'application (« Que voulez-vous commander ? »), la phrase de cette
    // enveloppe (« Que souhaitez-vous commander ? »), puis le titre de la
    // grille (« Que cherchez-vous ? »). Trois formulations du même besoin,
    // empilées, qui repoussaient les catégories hors de l'écran.
    //
    // Ne subsiste ici que ce qui n'est pas une redite du salut : la
    // dernière commande, quand il y en a une.
    // La dernière commande AVANT les catégories : c'est la réponse la plus
    // probable à « on mange quoi ? », et elle tient en un bouton.
    const derniere = await commandePrecedente(request);

    return reply.send(
      envelope(derniere?.ligne ?? '', [
        ...(derniere ? [derniere.composant] : []),
        categoryGrid(data ?? [], ''),
      ]),
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
    const query = z.object({ q: z.string().trim().min(2).max(120) }).safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });
    try {
      const intent = await resolveCatalogueIntent(db(request), query.data.q);
      const menu = await merchantIntentAnswer(db(request), intent);
      if (menu) return reply.send(envelope(menu.content, menu.components));
      let categoryId: string | undefined;
      if (demandeDeRepas(query.data.q) && !intent.merchants.length) {
        const { data, error } = await db(request).from('categories').select('id').eq('slug', 'restaurants-m3').maybeSingle();
        if (error) throw error;
        categoryId = data?.id as string | undefined;
      }
      const filter = {
        q: intent.query, category_id: categoryId, limit: 8,
        merchant_ids: intent.merchants.length ? intent.merchants.map((merchant) => merchant.id) : undefined,
      };
      const page = await cataloguePage(db(request), filter);
      const result = searchAnswer(page, filter);
      return reply.send(envelope(result.content, result.components));
    } catch (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
  });

  app.get('/catalog/products', async (request, reply) => {
    const query = z.object({
      q: z.string().trim().max(120).default(''),
      merchant_id: z.string().uuid().optional(),
      merchant_ids: z.string().transform((value) => value.split(',')).pipe(z.array(z.string().uuid()).max(20)).optional(),
      category_id: z.string().uuid().optional(),
      offset: z.coerce.number().int().min(0).max(100000).default(0),
      limit: z.coerce.number().int().min(1).max(60).default(24),
    }).safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: 'requête invalide' });
    try {
      const filter = { ...query.data, merchant_ids: query.data.merchant_id ? [query.data.merchant_id] : query.data.merchant_ids };
      const page = await cataloguePage(db(request), filter);
      let merchant: Record<string, unknown> | null = null;
      let categories: unknown[] = [];
      if (query.data.merchant_id) {
        const result = await db(request).from('merchants')
          .select('id, name, logo_url, address_hint, description').eq('id', query.data.merchant_id).eq('is_approved', true).maybeSingle();
        if (result.error) throw result.error;
        if (!result.data) return reply.code(404).send({ error: 'boutique introuvable' });
        const hours = await db(request).rpc('merchant_open_now', { p_merchant_id: query.data.merchant_id });
        if (hours.error) throw hours.error;
        merchant = { ...result.data, is_open: hours.data };
        const sections = await db(request).rpc('merchant_categories', { p_merchant_id: query.data.merchant_id });
        if (sections.error) throw sections.error;
        categories = sections.data ?? [];
      }
      return reply.send({ ...page, merchant, categories });
    } catch (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
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
      .select('name, browse_mode')
      .eq('id', params.data.categoryId)
      .maybeSingle();

    const nom = (categorie?.name as string | null) ?? 'Cette catégorie';

    /**
     * Les produits d'une catégorie, présentés en carrousel.
     *
     * Sert deux cas qui n'en font qu'un pour le client : la porte ouvre
     * directement sur des marchandises, ou elle ne cache qu'une seule
     * boutique et l'étape intermédiaire ne lui apprendrait rien.
     */
    const carrouselProduits = async () => {
      const { data: produits } = await db(request).rpc('category_products', {
        p_category_id: params.data.categoryId,
        p_limite: 20,
      });

      const items: ProductRow[] = ((produits ?? []) as Record<string, unknown>[]).map((p) => ({
        id: p['id'] as string,
        name: p['name'] as string,
        description: (p['description'] as string | null) ?? null,
        image_url: (p['image_url'] as string | null) ?? null,
        price: p['price'] as number,
        is_available: p['is_available'] as boolean,
        merchant_id: p['merchant_id'] as string,
        merchant_name: (p['merchant_name'] as string | null) ?? null,
      }));

      return items;
    };

    // MODE PRODUIT. Personne ne veut choisir l'enseigne avant le shampoing :
    // laquelle des vingt-deux boutiques l'a en stock est un détail
    // d'exécution qu'on faisait porter au client. Pour manger, à l'inverse,
    // le restaurant fait partie du choix — d'où le mode, par catégorie.
    if (categorie?.browse_mode === 'products') {
      const items = await carrouselProduits();
      if (items.length > 0) {
        return reply.send(envelope(nom, [productCarousel(items, nom)]));
      }
      return reply.send(envelope(`Rien dans ${nom} pour le moment.`));
    }

    const { data, error } = await db(request).rpc('category_merchants', {
      p_category_id: params.data.categoryId,
      p_lat: query.data.lat ?? null,
      p_lng: query.data.lng ?? null,
      p_limite: 50,
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

    // Aucune boutique : c'est presque toujours qu'on vise une catégorie
    // FEUILLE — « Pizza », « Boissons » — et non un module. Les boutiques ne
    // sont rattachées qu'aux racines ; une feuille, elle, porte des produits.
    //
    // Répondre « aucune boutique dans Pizza » serait faux : il y en a
    // quarante derrière. On bascule donc sur les produits plutôt que
    // d'exiger de l'appelant qu'il sache à quel niveau il se trouve.
    if (boutiques.length === 0) {
      const items = await carrouselProduits();
      if (items.length > 0) {
        return reply.send(envelope(nom, [productCarousel(items, nom)]));
      }
      return reply.send(envelope(`Rien dans ${nom} pour le moment.`));
    }

    // UNE SEULE BOUTIQUE : on saute son étape.
    //
    // « Parapharmacies » n'en a qu'une, « Gaz » aussi. Le client ouvrait la
    // porte, voyait une carte unique, la touchait, et découvrait enfin les
    // produits — deux gestes pour une information qu'il n'avait pas à
    // choisir. Le nom de la boutique reste visible sur chaque produit.
    //
    // On ne le fait que si elle est OUVERTE : sur une boutique fermée, la
    // carte dit pourquoi rien n'est commandable, là où un carrousel de
    // produits inertes ne l'expliquerait pas.
    if (boutiques.length === 1 && boutiques[0]!.is_open) {
      const items = await carrouselProduits();
      if (items.length > 0) {
        return reply.send(
          envelope(`${nom} — chez ${boutiques[0]!.name}`, [productCarousel(items, nom)]),
        );
      }
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
    const query = z.object({ category: z.string().uuid().optional() }).safeParse(request.query);
    if (!params.success || !query.success) return reply.code(400).send({ error: 'requête invalide' });
    try {
      if (!query.data.category) {
        const result = await merchantMenu(db(request), params.data.merchantId);
        return reply.send(envelope(result.content, result.components));
      }
      const filter = { merchant_ids: [params.data.merchantId], category_id: query.data.category, limit: 8 };
      const page = await cataloguePage(db(request), filter);
      return reply.send(envelope(`**${page.total} produits** dans cette catégorie.`, [
        productCarousel(page.items, 'Les produits', { merchant_id: params.data.merchantId, category_id: query.data.category, total: page.total }),
      ]));
    } catch (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
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
