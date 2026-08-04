import type { SupabaseClient } from '@supabase/supabase-js';
import type { LlmToolDefinition } from './llmClient.js';
import type { Component } from '../components/builders.js';
import {
  cartSummary,
  categoryGrid,
  merchantCard,
  optionSelector,
  orderTracking,
  productCard,
  productCarousel,
  quickReplies,
  type OptionRow,
  type ProductRow,
} from '../components/builders.js';
import { embed, embedImage } from '../services/embeddings.js';
import { serviceClient } from '../services/supabase.js';

/**
 * Les outils de l'assistant.
 *
 * Chacun renvoie deux choses de nature différente :
 *
 *   `summary`    — ce que le MODÈLE voit. Compact, factuel, sans redite.
 *                  Le modèle doit savoir qu'il a trouvé trois plats et
 *                  lesquels, pas recevoir le catalogue.
 *
 *   `components` — ce que l'UTILISATEUR voit. Construits ici, pas par le
 *                  modèle : il ne rédige jamais de JSON d'interface, il
 *                  choisit quel outil appeler.
 *
 * Cette séparation est ce qui rend le garde-fou possible. Les identifiants
 * des composants viennent des outils, donc de la base ; validate.ts n'a plus
 * qu'à vérifier que le modèle n'en a pas ajouté.
 *
 * AUCUN OUTIL NE VALIDE UNE COMMANDE. Passer commande engage de l'argent et
 * reste un geste explicite de l'utilisateur sur l'écran.
 */

export interface ToolContext {
  /** Client Supabase portant le JWT de l'utilisateur : la RLS s'applique. */
  db: SupabaseClient;
  userId: string;
  position?: { lat: number; lng: number } | undefined;
}

export interface ToolOutcome {
  summary: unknown;
  components: Component[];
}

type Executor = (args: Record<string, unknown>, ctx: ToolContext) => Promise<ToolOutcome>;

const vide: ToolOutcome = { summary: { resultats: 0 }, components: [] };

function texte(args: Record<string, unknown>, cle: string): string {
  const v = args[cle];
  return typeof v === 'string' ? v.trim() : '';
}

function nombre(args: Record<string, unknown>, cle: string): number | undefined {
  const v = args[cle];
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
}

/** Position de l'argument si fournie, sinon celle du contexte. */
function position(args: Record<string, unknown>, ctx: ToolContext) {
  const lat = nombre(args, 'lat') ?? ctx.position?.lat;
  const lng = nombre(args, 'lng') ?? ctx.position?.lng;
  return lat !== undefined && lng !== undefined ? { lat, lng } : undefined;
}

function versProductRow(ligne: Record<string, unknown>): ProductRow {
  return {
    id: ligne.id as string,
    name: ligne.name as string,
    description: (ligne.description as string | null) ?? null,
    image_url: (ligne.image_url as string | null) ?? null,
    price: (ligne.price as number) ?? 0,
    is_available: (ligne.is_available as boolean) ?? true,
    merchant_id: ligne.merchant_id as string,
    merchant_name: (ligne.merchant_name as string | null) ?? null,
    distance_m: (ligne.distance_m as number | null) ?? null,
  };
}

/** Ce que le modèle voit d'un produit : de quoi en parler, rien de plus. */
function resumeProduit(p: ProductRow) {
  return {
    id: p.id,
    nom: p.name,
    prix: p.price,
    boutique: p.merchant_name,
    distance_m: p.distance_m,
  };
}

// =====================================================================
// Exécuteurs
// =====================================================================

const listerCategories: Executor = async (_args, ctx) => {
  const { data } = await ctx.db
    .from('categories')
    .select('id, name, icon, image_url')
    .is('parent_id', null)
    .eq('is_active', true)
    .order('sort_order');

  const items = data ?? [];
  if (items.length === 0) return vide;

  return {
    summary: { categories: items.map((c) => ({ id: c.id, nom: c.name })) },
    components: [categoryGrid(items)],
  };
};

const rechercherProduits: Executor = async (args, ctx) => {
  const requete = texte(args, 'requete');
  if (!requete) return vide;

  const pos = position(args, ctx);
  const vecteur = await embed(requete, 'query').catch(() => null);

  const { data, error } = await ctx.db.rpc('search_products', {
    query_text: requete,
    query_embedding: vecteur ? JSON.stringify(vecteur) : null,
    origin_lat: pos?.lat ?? null,
    origin_lng: pos?.lng ?? null,
    radius_m: nombre(args, 'rayon_m') ?? null,
    filter_category: texte(args, 'categorie_id') || null,
    match_count: null,
  });

  if (error) throw error;

  const produits = ((data ?? []) as Record<string, unknown>[]).map(versProductRow);
  if (produits.length === 0) {
    return { summary: { resultats: 0, requete }, components: [] };
  }

  return {
    summary: { resultats: produits.length, produits: produits.map(resumeProduit) },
    components: [productCarousel(produits, requete)],
  };
};

const rechercherParImage: Executor = async (args, ctx) => {
  const chemin = texte(args, 'image_path');
  if (!chemin) return vide;

  // L'image est comparée DIRECTEMENT au catalogue, sans passer par une
  // description écrite.
  //
  // L'ancienne chaîne — photo, puis phrase, puis vecteur — perdait tout ce
  // que la phrase ne captait pas. Mesuré sur une photo de tacos : le modèle
  // de vision écrivait « chawarma », et la recherche cherchait du chawarma.
  // Les deux plats partagent leur pain, et les nommer dépend du pays. En
  // comparant les vecteurs d'image, le tacos ressort premier et le chawarma
  // second — ce qui est le classement juste.
  const { data: fichier, error: erreurFichier } = await serviceClient()
    .storage.from('search-images')
    .download(chemin);

  if (erreurFichier || !fichier) {
    return { summary: { erreur: 'image introuvable' }, components: [] };
  }

  const octets = Buffer.from(await fichier.arrayBuffer());
  const vecteur = await embedImage(octets, fichier.type || 'image/jpeg');
  const pos = position(args, ctx);

  const { data, error } = await ctx.db.rpc('search_products', {
    query_text: '',
    query_embedding: JSON.stringify(vecteur),
    origin_lat: pos?.lat ?? null,
    origin_lng: pos?.lng ?? null,
    radius_m: null,
    filter_category: null,
    match_count: null,
  });

  if (error) throw error;

  const produits = ((data ?? []) as Record<string, unknown>[]).map(versProductRow);

  return {
    // On ne dit PAS au modèle ce que la photo représente : on ne le sait
    // pas, et le lui affirmer l'amènerait à le répéter à l'utilisateur.
    // Il annonce des ressemblances, pas une identification.
    summary: {
      recherche: 'par image',
      resultats: produits.length,
      produits: produits.map(resumeProduit),
    },
    components:
      produits.length > 0
        ? [productCarousel(produits, 'Ce qui ressemble à votre photo')]
        : [],
  };
};

const boutiquesProches: Executor = async (args, ctx) => {
  const pos = position(args, ctx);
  if (!pos) return { summary: { erreur: 'position inconnue' }, components: [] };

  const { data, error } = await ctx.db.rpc('nearby_merchants', {
    origin_lat: pos.lat,
    origin_lng: pos.lng,
    radius_m: nombre(args, 'rayon_m') ?? 5000,
    filter_category: texte(args, 'categorie_id') || null,
    match_count: 8,
  });

  if (error) throw error;

  const boutiques = (data ?? []) as Array<Record<string, unknown>>;
  if (boutiques.length === 0) return vide;

  return {
    summary: {
      boutiques: boutiques.map((m) => ({
        id: m.id,
        nom: m.name,
        ouverte: m.is_open,
        distance_m: m.distance_m,
      })),
    },
    components: boutiques.map((m) =>
      merchantCard({
        id: m.id as string,
        name: m.name as string,
        description: (m.description as string | null) ?? null,
        logo_url: (m.logo_url as string | null) ?? null,
        address_hint: (m.address_hint as string) ?? '',
        is_open: (m.is_open as boolean) ?? false,
        rating: (m.rating as number) ?? 5,
        prep_time_min: (m.prep_time_min as number) ?? 20,
        distance_m: (m.distance_m as number | null) ?? null,
      }),
    ),
  };
};

const obtenirProduit: Executor = async (args, ctx) => {
  const id = texte(args, 'product_id');
  if (!id) return vide;

  const { data: produit } = await ctx.db
    .from('products')
    .select('id, name, description, image_url, price, is_available, merchant_id, merchants(name)')
    .eq('id', id)
    .maybeSingle();

  if (!produit) return { summary: { erreur: 'produit introuvable' }, components: [] };

  const row = versProductRow({
    ...produit,
    merchant_name: (produit.merchants as { name?: string } | null)?.name ?? null,
  });

  const { data: options } = await ctx.db
    .from('product_options')
    .select(
      'id, name, is_required, min_select, max_select, sort_order, product_option_values(id, name, price_delta, is_available, sort_order)',
    )
    .eq('product_id', id)
    .order('sort_order');

  const rows: OptionRow[] = (options ?? []).map((o) => ({
    id: o.id as string,
    name: o.name as string,
    is_required: o.is_required as boolean,
    min_select: o.min_select as number,
    max_select: o.max_select as number,
    values: ((o.product_option_values ?? []) as Array<Record<string, unknown>>).map((v) => ({
      id: v.id as string,
      name: v.name as string,
      price_delta: v.price_delta as number,
      is_available: v.is_available as boolean,
    })),
  }));

  return {
    summary: {
      produit: resumeProduit(row),
      options: rows.map((o) => ({
        id: o.id,
        nom: o.name,
        obligatoire: o.is_required,
        valeurs: o.values.map((v) => ({ id: v.id, nom: v.name, supplement: v.price_delta })),
      })),
    },
    // Un produit à options ne doit jamais exposer « ajouter » directement :
    // la base refuserait l'ajout sans les choix obligatoires.
    components: rows.length > 0 ? [optionSelector(row, rows)] : [productCard(row)],
  };
};

const comparerPrix: Executor = async (args, ctx) => {
  const requete = texte(args, 'requete');
  const pos = position(args, ctx);
  if (!requete || !pos) {
    return { summary: { erreur: 'requête ou position manquante' }, components: [] };
  }

  const vecteur = await embed(requete, 'query');

  const { data, error } = await ctx.db.rpc('compare_prices', {
    query_embedding: JSON.stringify(vecteur),
    origin_lat: pos.lat,
    origin_lng: pos.lng,
    radius_m: 8000,
    match_count: 6,
  });

  if (error) throw error;

  const lignes = (data ?? []) as Array<Record<string, unknown>>;
  if (lignes.length === 0) return { summary: { resultats: 0, requete }, components: [] };

  const results = lignes.map((l) => ({
    source_kind: l.source_kind,
    ref_id: l.ref_id,
    seller_name: l.seller_name,
    product_name: l.product_name,
    price: l.price,
    distance_m: l.distance_m,
    in_stock: l.in_stock,
    is_orderable: l.is_orderable,
    source_url: l.source_url,
  }));

  return {
    summary: {
      requete,
      offres: results.map((r) => ({
        vendeur: r.seller_name,
        prix: r.price,
        commandable: r.is_orderable,
      })),
    },
    components: [
      {
        type: 'price_comparison',
        data: { product_query: requete, currency: 'XOF', results },
      },
    ],
  };
};

/** Recharge le panier et le rend sous forme de composant. */
async function panierCourant(ctx: ToolContext): Promise<ToolOutcome> {
  const { data, error } = await ctx.db.rpc('cart_view', {
    p_lat: ctx.position?.lat ?? null,
    p_lng: ctx.position?.lng ?? null,
  });

  if (error) throw error;

  const payload = (data ?? {}) as Record<string, unknown>;
  const items = (payload.items as unknown[]) ?? [];

  if (!payload.cart_id || items.length === 0) {
    return { summary: { panier: 'vide' }, components: [] };
  }

  return {
    summary: {
      articles: items.length,
      total: payload.total,
      boutique: payload.merchant_name,
      commandable: payload.can_checkout,
    },
    components: [cartSummary(payload)],
  };
}

const ajouterAuPanier: Executor = async (args, ctx) => {
  const productId = texte(args, 'product_id');
  if (!productId) return vide;

  const { error } = await ctx.db.rpc('cart_add_item', {
    p_product_id: productId,
    p_quantity: nombre(args, 'quantite') ?? 1,
    p_selections: Array.isArray(args.selections) ? args.selections : [],
  });

  if (error) {
    // Panier ouvert chez une autre boutique : on rend la main à
    // l'utilisateur au lieu de vider son panier en douce.
    if (error.code === 'P0003') {
      return {
        summary: { erreur: 'panier ouvert chez une autre boutique' },
        components: [
          quickReplies([
            { label: 'Vider et recommencer', value: 'vider_panier' },
            { label: 'Garder mon panier', value: 'garder_panier' },
          ]),
        ],
      };
    }
    return { summary: { erreur: error.message }, components: [] };
  }

  return panierCourant(ctx);
};

const voirPanier: Executor = async (_args, ctx) => panierCourant(ctx);

const retirerDuPanier: Executor = async (args, ctx) => {
  const itemId = texte(args, 'item_id');
  if (!itemId) return vide;

  const { error } = await ctx.db.rpc('cart_set_quantity', {
    p_item_id: itemId,
    p_quantity: 0,
  });
  if (error) return { summary: { erreur: error.message }, components: [] };

  return panierCourant(ctx);
};

const suivreCommande: Executor = async (args, ctx) => {
  let orderId = texte(args, 'order_id');

  // Sans identifiant, on prend la dernière commande en cours : c'est ce que
  // « où est ma commande ? » veut dire dans 99 % des cas.
  if (!orderId) {
    const { data } = await ctx.db
      .from('orders')
      .select('id')
      .not('status', 'in', '("delivered","cancelled")')
      .order('placed_at', { ascending: false })
      .limit(1);
    orderId = (data?.[0]?.id as string | undefined) ?? '';
  }

  if (!orderId) return { summary: { commandes_en_cours: 0 }, components: [] };

  const { data, error } = await ctx.db.rpc('order_tracking', { p_order_id: orderId });
  if (error || !data) return { summary: { erreur: 'commande introuvable' }, components: [] };

  const payload = data as Record<string, unknown>;

  return {
    summary: {
      order_id: payload.order_id,
      statut: payload.status,
      total: payload.total,
      livreur: (payload.driver as { name?: string } | null)?.name ?? null,
    },
    components: [orderTracking(payload)],
  };
};

/**
 * Les adresses enregistrées du client.
 *
 * À Niamey il n'y a pas d'adresse postale : on se repère par des indices,
 * et « Yantala, derrière la pharmacie Al Nour » est pénible à retaper sur un
 * clavier de téléphone à chaque commande. Que l'assistant puisse demander
 * « je livre chez vous ? » supprime cette friction.
 *
 * Le repère complet part dans le résumé destiné au modèle, mais les réponses
 * rapides n'affichent que le libellé : « Livrer à Maison » tient dans un
 * bouton, pas l'indice en entier.
 */
const mesAdresses: Executor = async (_args, ctx) => {
  const { data } = await ctx.db.rpc('my_addresses');
  const adresses = (data ?? []) as Array<{
    id: string;
    label: string;
    text_hint: string;
    is_default: boolean;
  }>;

  if (adresses.length === 0) return { summary: { adresses: 0 }, components: [] };

  return {
    summary: {
      adresses: adresses.map((a) => ({
        id: a.id,
        libelle: a.label,
        repere: a.text_hint,
        par_defaut: a.is_default,
      })),
    },
    components: [
      quickReplies([
        ...adresses.slice(0, 3).map((a) => ({
          label: `Livrer à ${a.label}`,
          value: `adresse:${a.id}`,
        })),
        { label: 'Ailleurs', value: 'adresse:nouvelle' },
      ]),
    ],
  };
};

const historiqueCommandes: Executor = async (args, ctx) => {
  const limite = Math.min(nombre(args, 'limite') ?? 5, 10);

  const { data } = await ctx.db
    .from('orders')
    .select('id, type, status, total, placed_at, dropoff_hint')
    .eq('status', 'delivered')
    .order('placed_at', { ascending: false })
    .limit(limite);

  const commandes = data ?? [];
  if (commandes.length === 0) return { summary: { commandes: 0 }, components: [] };

  return {
    summary: {
      commandes: commandes.map((o) => ({
        id: o.id,
        total: o.total,
        date: o.placed_at,
        type: o.type,
      })),
    },
    components: [
      quickReplies(
        commandes.slice(0, 3).map((o) => ({
          label: `Recommander (${o.total} F)`,
          value: `recommander:${o.id}`,
        })),
      ),
    ],
  };
};

const preparerCourse: Executor = async (args, ctx) => {
  const depart = args.depart as { lat?: number; lng?: number; hint?: string } | undefined;
  const arrivee = args.arrivee as { lat?: number; lng?: number; hint?: string } | undefined;
  const colis = texte(args, 'colis') || 'small';

  let estimate: Record<string, unknown> | null = null;

  if (depart?.lat && depart?.lng && arrivee?.lat && arrivee?.lng) {
    // L'estimation vient de la base : les coefficients sont dans
    // platform_settings, pilotés par l'admin, jamais calculés ici.
    const { data } = await ctx.db.rpc('courier_price', {
      p_distance_m: Math.round(
        distanceMetres(depart.lat, depart.lng, arrivee.lat, arrivee.lng),
      ),
      p_parcel: colis,
    });
    if (typeof data === 'number') {
      estimate = {
        price: data,
        distance_m: Math.round(
          distanceMetres(depart.lat, depart.lng, arrivee.lat, arrivee.lng),
        ),
      };
    }
  }

  return {
    summary: {
      depart: depart?.hint ?? null,
      arrivee: arrivee?.hint ?? null,
      colis,
      estimation: estimate?.price ?? null,
      complet: Boolean(estimate),
    },
    components: [
      {
        type: 'courier_form',
        data: {
          pickup: depart ?? null,
          dropoff: arrivee ?? null,
          parcel: colis,
          parcel_options: [
            { value: 'small', label: 'Petit', icon: '📍', hint: 'documents, clés' },
            { value: 'medium', label: 'Moyen', icon: '📦', hint: 'sac, carton' },
            { value: 'large', label: 'Grand', icon: '🗃', hint: 'encombrant' },
          ],
          scheduling: ['now', 'later'],
          estimate,
          confirm_label: estimate ? `Confirmer l'envoi — ${estimate.price} F` : null,
        },
      },
    ],
  };
};

/** Haversine — suffisant pour une estimation, la base fait foi au final. */
function distanceMetres(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6_371_000;
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// =====================================================================
// Déclarations pour le modèle
// =====================================================================

const S = {
  string: (description: string) => ({ type: 'string', description }),
  number: (description: string) => ({ type: 'number', description }),
};

export const TOOL_DEFINITIONS: LlmToolDefinition[] = [
  {
    name: 'lister_categories',
    description:
      "Liste les catégories de produits disponibles. À utiliser au début d'une conversation ou quand l'utilisateur ne sait pas quoi commander.",
    parameters: { type: 'object', properties: {} },
  },
  {
    name: 'rechercher_produits',
    description:
      "Cherche des produits par description en langage naturel. Comprend le sens et tolère les fautes. À utiliser dès que l'utilisateur nomme ou décrit ce qu'il veut manger ou acheter.",
    parameters: {
      type: 'object',
      properties: {
        requete: S.string("Ce que cherche l'utilisateur, dans ses mots"),
        categorie_id: S.string('Identifiant de catégorie, si la recherche doit être restreinte'),
        rayon_m: S.number('Rayon de recherche en mètres'),
      },
      required: ['requete'],
    },
  },
  {
    name: 'rechercher_par_image',
    description:
      "Cherche un produit à partir d'une photo envoyée par l'utilisateur. À utiliser uniquement quand une interaction search_by_image fournit un image_path.",
    parameters: {
      type: 'object',
      properties: { image_path: S.string('Chemin Storage fourni par l’interaction') },
      required: ['image_path'],
    },
  },
  {
    name: 'boutiques_proches',
    description:
      "Liste les boutiques ouvertes autour de l'utilisateur. À utiliser quand il demande où acheter, ou quelles boutiques sont ouvertes.",
    parameters: {
      type: 'object',
      properties: {
        rayon_m: S.number('Rayon en mètres, 5000 par défaut'),
        categorie_id: S.string('Restreindre à une catégorie'),
      },
    },
  },
  {
    name: 'obtenir_produit',
    description:
      "Détaille un produit et ses options. À appeler OBLIGATOIREMENT avant tout ajout au panier, pour connaître les choix disponibles.",
    parameters: {
      type: 'object',
      properties: { product_id: S.string('Identifiant renvoyé par une recherche') },
      required: ['product_id'],
    },
  },
  {
    name: 'comparer_prix',
    description:
      "Compare le prix d'un produit entre plusieurs vendeurs, partenaires et externes. À utiliser quand l'utilisateur demande le moins cher ou veut comparer.",
    parameters: {
      type: 'object',
      properties: { requete: S.string('Produit à comparer') },
      required: ['requete'],
    },
  },
  {
    name: 'ajouter_au_panier',
    description:
      "Ajoute un produit au panier. Les options obligatoires doivent être renseignées, sinon l'ajout est refusé.",
    parameters: {
      type: 'object',
      properties: {
        product_id: S.string('Identifiant du produit'),
        quantite: S.number('Quantité, 1 par défaut'),
        selections: {
          type: 'array',
          description: 'Options retenues',
          items: {
            type: 'object',
            properties: {
              option_id: S.string("Identifiant de l'option"),
              value_ids: { type: 'array', items: { type: 'string' } },
            },
          },
        },
      },
      required: ['product_id'],
    },
  },
  {
    name: 'voir_panier',
    description: 'Affiche le panier courant avec son total.',
    parameters: { type: 'object', properties: {} },
  },
  {
    name: 'retirer_du_panier',
    description: 'Retire un article du panier.',
    parameters: {
      type: 'object',
      properties: { item_id: S.string("Identifiant de la ligne de panier") },
      required: ['item_id'],
    },
  },
  {
    name: 'suivre_commande',
    description:
      "Affiche le suivi d'une commande. Sans identifiant, prend la dernière commande en cours.",
    parameters: {
      type: 'object',
      properties: { order_id: S.string('Identifiant de commande') },
    },
  },
  {
    name: 'historique_commandes',
    description:
      "Liste les commandes déjà livrées, pour permettre d'en recommander une.",
    parameters: {
      type: 'object',
      properties: { limite: S.number('Nombre de commandes, 5 par défaut') },
    },
  },
  {
    name: 'mes_adresses',
    description:
      "Les adresses de livraison enregistrées par le client, la sienne par défaut en tête. " +
      "À appeler AVANT de proposer de commander, pour demander « je livre chez vous, à … ? » " +
      "au lieu de faire retaper le repère. Ne renvoie rien si le client n'en a aucune : " +
      "dans ce cas, laisser le formulaire de commande demander la position.",
    parameters: { type: 'object', properties: {} },
  },
  {
    name: 'preparer_course',
    description:
      "Prépare une course coursier : colis d'un point à un autre, sans boutique. Renvoie une estimation dès que les deux points sont connus. Ne valide jamais l'envoi.",
    parameters: {
      type: 'object',
      properties: {
        depart: {
          type: 'object',
          description: 'Point de prise en charge',
          properties: { lat: S.number('Latitude'), lng: S.number('Longitude'), hint: S.string('Repère') },
        },
        arrivee: {
          type: 'object',
          description: 'Point de livraison',
          properties: { lat: S.number('Latitude'), lng: S.number('Longitude'), hint: S.string('Repère') },
        },
        colis: S.string('small, medium ou large'),
      },
    },
  },
];

export const EXECUTORS: Record<string, Executor> = {
  lister_categories: listerCategories,
  rechercher_produits: rechercherProduits,
  rechercher_par_image: rechercherParImage,
  boutiques_proches: boutiquesProches,
  obtenir_produit: obtenirProduit,
  comparer_prix: comparerPrix,
  ajouter_au_panier: ajouterAuPanier,
  voir_panier: voirPanier,
  retirer_du_panier: retirerDuPanier,
  suivre_commande: suivreCommande,
  historique_commandes: historiqueCommandes,
  mes_adresses: mesAdresses,
  preparer_course: preparerCourse,
};
