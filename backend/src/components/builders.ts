/**
 * Constructeurs de composants du contrat UI (docs/tovo_ui_contract.md).
 *
 * En Phase 2, ce sont les routes REST qui les appellent, avec des données
 * venues de la base — pas d'IA. En Phase 4, l'orchestrateur appellera
 * exactement les mêmes fonctions. Le contrat ne bouge pas : seule la source
 * des composants change.
 *
 * Aucune mise en forme ici. Les montants restent des entiers XOF, les
 * distances des mètres. Le formatage appartient à Flutter.
 */

export interface Component {
  type: string;
  data: Record<string, unknown>;
}

export interface ChatEnvelope {
  content: string;
  components: Component[];
  contract_version: number;
}

export const CONTRACT_VERSION = 1;

export function envelope(content: string, components: Component[] = []): ChatEnvelope {
  return { content, components, contract_version: CONTRACT_VERSION };
}

// --- catalogue ---------------------------------------------------------

export interface CategoryRow {
  id: string;
  name: string;
  /**
   * Clé de l'icône embarquée dans l'application.
   *
   * Ni l'UUID ni le nom ne conviennent : l'un oblige à republier l'app si la
   * base est réamorcée, l'autre change dès qu'on renomme une catégorie.
   * Absent sur les rayons de boutique, qui n'ont pas d'icône dédiée.
   */
  slug?: string | null;
  icon: string | null;
  image_url: string | null;
  /**
   * Boutique dont cette entrée est un RAYON, si c'en est un.
   *
   * La même grille sert aux catégories du catalogue et aux rayons d'une
   * boutique. Sans cette distinction, toucher « Boissons » chez GALAXIE
   * renverrait vers toutes les boissons de Niamey.
   */
  merchant_id?: string | null;
  produits?: number | null;
}

export function categoryGrid(items: CategoryRow[], title = 'Que cherchez-vous ?'): Component {
  return {
    type: 'category_grid',
    data: {
      title,
      items: items.map((c) => ({
        id: c.id,
        name: c.name,
        icon: c.icon,
        image_url: c.image_url,
        ...(c.slug ? { slug: c.slug } : {}),
        ...(c.merchant_id ? { merchant_id: c.merchant_id } : {}),
        ...(c.produits != null ? { produits: c.produits } : {}),
      })),
    },
  };
}

export interface ProductRow {
  id: string;
  name: string;
  description?: string | null;
  image_url: string | null;
  price: number;
  is_available: boolean;
  merchant_id: string;
  merchant_name?: string | null;
  /**
   * La boutique sert-elle en ce moment ?
   *
   * Affiché plutôt que filtré : à 8 h du matin presque tout est fermé à
   * Niamey, et une recherche qui ne renverrait rien ferait croire que Tovo
   * est vide. Mieux vaut montrer et dire.
   */
  merchant_open?: boolean | null;
  distance_m?: number | null;
}

function productItem(p: ProductRow): Record<string, unknown> {
  return {
    id: p.id,
    name: p.name,
    merchant_id: p.merchant_id,
    merchant_name: p.merchant_name ?? null,
    image_url: p.image_url,
    price: p.price,
    is_available: p.is_available,
    distance_m: p.distance_m ?? null,
  };
}

/**
 * Le contrat plafonne à 8 éléments. La limite est appliquée ici plutôt que
 * laissée à chaque appelant : un carrousel de 200 produits est une
 * régression silencieuse, pas une fonctionnalité.
 */
const MAX_ITEMS = 8;

export function productCarousel(items: ProductRow[], title: string): Component {
  return {
    type: 'product_carousel',
    data: { title, items: items.slice(0, MAX_ITEMS).map(productItem) },
  };
}

export function productList(items: ProductRow[], title: string): Component {
  return {
    type: 'product_list',
    data: { title, items: items.slice(0, MAX_ITEMS).map(productItem) },
  };
}

export interface OptionValueRow {
  id: string;
  name: string;
  price_delta: number;
  is_available: boolean;
}

export interface OptionRow {
  id: string;
  name: string;
  is_required: boolean;
  min_select: number;
  max_select: number;
  values: OptionValueRow[];
}

/**
 * Un produit qui a des options obligatoires ne doit jamais exposer
 * « ajouter au panier » directement — c'est la règle du contrat, et la base
 * la fait respecter de toute façon en refusant l'ajout.
 */
export function optionSelector(
  product: ProductRow,
  options: OptionRow[],
  quantity = 1,
): Component {
  return {
    type: 'option_selector',
    data: {
      product_id: product.id,
      product_name: product.name,
      base_price: product.price,
      quantity,
      options: options.map((o) => ({
        id: o.id,
        name: o.name,
        required: o.is_required,
        min_select: o.min_select,
        max_select: o.max_select,
        values: o.values.map((v) => ({
          id: v.id,
          name: v.name,
          price_delta: v.price_delta,
          available: v.is_available,
        })),
      })),
      confirm_label: 'Ajouter au panier',
    },
  };
}

export function productCard(product: ProductRow, actions: string[] = ['add_to_cart']): Component {
  return {
    type: 'product_card',
    data: { ...productItem(product), description: product.description ?? null, actions },
  };
}

export interface MerchantRow {
  id: string;
  name: string;
  description: string | null;
  logo_url: string | null;
  address_hint: string;
  is_open: boolean;
  rating: number;
  prep_time_min: number;
  distance_m?: number | null;
}

export function merchantCard(m: MerchantRow): Component {
  return {
    type: 'merchant_card',
    data: {
      id: m.id,
      name: m.name,
      description: m.description,
      logo_url: m.logo_url,
      address_hint: m.address_hint,
      is_open: m.is_open,
      rating: m.rating,
      prep_time_min: m.prep_time_min,
      distance_m: m.distance_m ?? null,
    },
  };
}

// --- panier ------------------------------------------------------------

/**
 * `cart_view()` renvoie déjà la charge utile dans la forme du contrat : on
 * l'enveloppe sans la retoucher. Recalculer un total ici serait ouvrir la
 * porte à une divergence entre ce que la base facture et ce que l'écran
 * affiche.
 */
export function cartSummary(payload: Record<string, unknown>): Component {
  const total = Number(payload.total ?? 0);
  return {
    type: 'cart_summary',
    data: {
      ...payload,
      checkout_label: `Commander — ${total} F`,
    },
  };
}

export function quickReplies(items: Array<{ label: string; value: string }>): Component {
  return { type: 'quick_replies', data: { items: items.slice(0, 4) } };
}

// --- suivi -------------------------------------------------------------

const ETAPES_LIVRAISON = [
  'confirmed',
  'preparing',
  'ready',
  'picked_up',
  'delivering',
  'delivered',
];

const ETAPES_COURSIER = ['confirmed', 'assigned', 'picked_up', 'delivering', 'delivered'];

const LIBELLES: Record<string, string> = {
  pending: 'En attente de confirmation',
  confirmed: 'Commande confirmée',
  preparing: 'En préparation',
  ready: 'Prête, en attente d’un livreur',
  assigned: 'Un livreur arrive',
  picked_up: 'Commande récupérée',
  delivering: 'En route vers vous',
  delivered: 'Livrée',
  cancelled: 'Annulée',
};

export function orderTracking(payload: Record<string, unknown>): Component {
  const orderId = String(payload.order_id ?? '');
  const status = String(payload.status ?? 'pending');
  const type = String(payload.type ?? 'delivery');
  const driver = payload.driver as { id?: string } | null;

  return {
    type: 'order_tracking',
    data: {
      ...payload,
      status_label: LIBELLES[status] ?? status,
      steps: type === 'courier' ? ETAPES_COURSIER : ETAPES_LIVRAISON,
      realtime: {
        orders_channel: `orders:${orderId}`,
        // Pas de canal livreur tant qu'aucun livreur n'est assigné :
        // Flutter s'abonnerait à un flux vide et le composant afficherait
        // une carte sans point.
        driver_channel: driver?.id ? `driver_locations:${orderId}` : null,
      },
    },
  };
}

export function imageSearchPrompt(
  message = 'Montrez-moi une photo, je trouve où l’acheter',
): Component {
  return {
    type: 'image_search_prompt',
    data: { message, allow_camera: true, allow_gallery: true },
  };
}
