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
import { decrireImage } from '../services/vision.js';

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
    merchant_open: (ligne.merchant_open as boolean | null) ?? null,
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
  // Seulement celles qui mènent à des produits : proposer une catégorie
  // vide fait croire au client que l'application l'est aussi.
  const { data } = await ctx.db.rpc('browsable_categories');

  const items = (data ?? []) as Array<{
    id: string;
    name: string;
    icon: string | null;
    image_url: string | null;
  }>;
  if (items.length === 0) return vide;

  return {
    summary: { categories: items.map((c) => ({ id: c.id, nom: c.name })) },
    components: [categoryGrid(items)],
  };
};

/**
 * Retrouve les boutiques nommées par le client.
 *
 * « chez otakoss » désigne « O'TAKOSS ( Centre Aéré ) » : apostrophe,
 * capitales, parenthèses. On compare donc sur une forme réduite aux lettres
 * et aux chiffres, sinon aucune correspondance ne se ferait.
 *
 * Rend une liste vide plutôt que de deviner. Une boutique introuvable doit
 * être annoncée au client, pas remplacée en silence par une autre.
 */
async function boutiquesNommees(ctx: ToolContext, nom: string): Promise<string[]> {
  const reduire = (t: string) => t.toLowerCase().replace(/[^a-z0-9]/g, '');
  const cible = reduire(nom);
  if (cible.length < 3) return [];

  const { data } = await ctx.db
    .from('merchants')
    .select('id, name')
    .eq('is_approved', true)
    .limit(500);

  const boutiques = (data ?? []) as Array<{ id: string; name: string }>;

  // TOUTES les correspondances, pas la première. « chez otakoss » désigne
  // l'enseigne, et O'TAKOSS a deux adresses : en retenir une masquerait la
  // moitié de sa carte sans que rien ne le signale.
  const exactes = boutiques.filter((b) => reduire(b.name) === cible);
  if (exactes.length > 0) return exactes.map((b) => b.id);

  return boutiques.filter((b) => reduire(b.name).includes(cible)).map((b) => b.id);
}

/**
 * Les options qui répondent à la demande du client.
 *
 * La recherche sait remonter un Tacos parce qu'il propose la boulette
 * (migration 0042), mais le résultat ne dit pas POURQUOI il remonte : le
 * modèle reçoit un nom, un prix, une boutique. Il voyait donc « Tacos Bowl »
 * et concluait honnêtement « je n'ai pas de tacos aux boulettes » — alors
 * que la boulette y est, à +600 F.
 *
 * Sans cette information, la branche options de la recherche travaille pour
 * rien : elle place le bon produit devant, et personne ne peut le dire.
 */
async function optionsCorrespondantes(
  ctx: ToolContext,
  requete: string,
  ids: string[],
): Promise<Map<string, string[]>> {
  const resultat = new Map<string, string[]>();
  if (ids.length === 0) return resultat;

  // Les mêmes règles que la migration 0042, sinon l'explication ne
  // correspondrait pas à ce qui a fait remonter le produit.
  const reduire = (s: string) =>
    s
      .toLowerCase()
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .split(/[^a-z0-9]+/)
      .filter(Boolean)
      .map((m) => m.replace(/s$/, ''));

  const motsRequete = new Set(reduire(requete).filter((m) => m.length >= 4));
  if (motsRequete.size === 0) return resultat;

  const { data } = await ctx.db
    .from('product_options')
    .select('product_id, product_option_values(name, price_delta, is_available)')
    .in('product_id', ids);

  type Valeur = { name: string; price_delta: number | null; is_available: boolean };
  for (const groupe of (data ?? []) as Array<{
    product_id: string;
    product_option_values: Valeur[] | null;
  }>) {
    for (const v of groupe.product_option_values ?? []) {
      if (!v.is_available) continue;
      if (!reduire(v.name).some((m) => motsRequete.has(m))) continue;

      const supplement = v.price_delta ?? 0;
      const libelle = supplement > 0 ? `${v.name} (+${supplement} F)` : v.name;
      const liste = resultat.get(groupe.product_id) ?? [];
      if (!liste.includes(libelle)) liste.push(libelle);
      resultat.set(groupe.product_id, liste);
    }
  }

  return resultat;
}

const rechercherProduits: Executor = async (args, ctx) => {
  const requete = texte(args, 'requete');
  if (!requete) return vide;

  const pos = position(args, ctx);

  const nomBoutique = texte(args, 'boutique');
  const boutiqueIds = nomBoutique ? await boutiquesNommees(ctx, nomBoutique) : [];

  // Nom donné mais introuvable : on ne cherche PAS partout. Rendre les tacos
  // du voisin à qui demande ceux d'otakoss est pire que de ne rien rendre,
  // parce que rien ne signale la substitution.
  if (nomBoutique && boutiqueIds.length === 0) {
    return {
      summary: { resultats: 0, requete, boutique_introuvable: nomBoutique },
      components: [],
    };
  }

  const vecteur = await embed(requete, 'query').catch(() => null);

  const { data, error } = await ctx.db.rpc('search_products', {
    query_text: requete,
    query_embedding: vecteur ? JSON.stringify(vecteur) : null,
    origin_lat: pos?.lat ?? null,
    origin_lng: pos?.lng ?? null,
    radius_m: nombre(args, 'rayon_m') ?? null,
    filter_category: texte(args, 'categorie_id') || null,
    match_count: null,
    filter_merchants: boutiqueIds.length > 0 ? boutiqueIds : null,
  });

  if (error) throw error;

  const produits = ((data ?? []) as Record<string, unknown>[]).map(versProductRow);
  if (produits.length === 0) {
    return { summary: { resultats: 0, requete }, components: [] };
  }

  // Ce qui, dans les OPTIONS, répond à la demande. Le modèle peut alors
  // dire « le Tacos M existe, la boulette est une garniture à +600 F »
  // au lieu de « je n'ai pas de tacos aux boulettes ».
  const options = await optionsCorrespondantes(
    ctx,
    requete,
    produits.map((p) => p.id),
  );

  return {
    summary: {
      resultats: produits.length,
      produits: produits.map((p) => {
        const trouvees = options.get(p.id);
        return trouvees && trouvees.length > 0
          ? { ...resumeProduit(p), options_disponibles: trouvees }
          : resumeProduit(p);
      }),
    },
    components: [productCarousel(produits, requete)],
  };
};

const rechercherParImage: Executor = async (args, ctx) => {
  const chemin = texte(args, 'image_path');
  if (!chemin) return vide;

  // LA PHOTO EST COMPARÉE AUX PHOTOS DU CATALOGUE, avec les mots-clés en
  // repli.
  //
  // Ça n'a pas toujours été possible. Les produits n'étaient vectorisés que
  // depuis leur TEXTE, et comparer une image à des vecteurs de texte ne
  // séparait rien — mesuré : une autre souris notait 0,31 à 0,40, un produit
  // au hasard 0,33 à 0,36. Le chemin par mots-clés était alors le seul qui
  // marchait.
  //
  // Depuis, les 2 058 produits ont un vecteur calculé depuis leur propre
  // photo. Calibré sur les VRAIES photos des clients, prises au téléphone :
  // six photos de souris sur six retrouvent la bonne souris en tête, entre
  // 0,676 et 0,708.
  //
  // Les mots-clés restent, et ne sont pas un vestige : ils rattrapent ce que
  // le visuel ne sait pas faire. Un emballage lu de travers, un produit dont
  // la photo du catalogue est mauvaise, une catégorie entière sans photo —
  // le nom, lui, est toujours là.
  const pos = position(args, ctx);

  const { data: fichier, error: erreurFichier } = await serviceClient()
    .storage.from('search-images')
    .download(chemin);

  if (!erreurFichier && fichier) {
    try {
      const octets = Buffer.from(await fichier.arrayBuffer());
      const vecteur = await embedImage(octets, fichier.type || 'image/jpeg');

      const { data, error } = await ctx.db.rpc('search_by_photo', {
        query_embedding: JSON.stringify(vecteur),
        origin_lat: pos?.lat ?? null,
        origin_lng: pos?.lng ?? null,
        radius_m: null,
        match_count: null,
      });
      if (error) throw error;

      const produits = ((data ?? []) as Record<string, unknown>[]).map(versProductRow);

      if (produits.length > 0) {
        const meilleur = Number((data as Record<string, unknown>[])[0]?.['score'] ?? 0);
        return {
          summary: {
            recherche: 'par ressemblance visuelle',
            // Le score est ici une vraie similarité, pas une fusion de
            // classements : le modèle peut donc juger de la qualité de la
            // correspondance et le dire, au lieu de présenter une
            // approximation comme une trouvaille.
            ressemblance: meilleur.toFixed(2),
            resultats: produits.length,
            produits: produits.map(resumeProduit),
          },
          components: [productCarousel(produits, 'Ce qui ressemble à votre photo')],
        };
      }
    } catch {
      // Le visuel a échoué — image illisible, API indisponible. On ne
      // s'arrête pas là : les mots-clés ci-dessous sont une seconde chance,
      // et le client n'a pas à savoir laquelle des deux a répondu.
    }
  }

  let motsCles: string;
  try {
    motsCles = (await decrireImage(chemin)).trim();
  } catch (cause) {
    return {
      summary: { erreur: cause instanceof Error ? cause.message : 'image illisible' },
      components: [],
    };
  }

  if (motsCles === '') {
    return { summary: { recherche: 'par image', resultats: 0 }, components: [] };
  }

  const produits = await chercherEnRaccourcissant(ctx, motsCles, pos);

  return {
    summary: {
      recherche: 'par mots-clés lus sur la photo',
      // Ce que la photo a donné comme mots-clés. Le modèle peut ainsi dire
      // « je vois une souris sans fil » plutôt que « je n'ai rien trouvé » :
      // le client sait alors si c'est la photo ou le catalogue qui a manqué.
      lu_sur_la_photo: motsCles,
      resultats: produits.length,
      produits: produits.map(resumeProduit),
    },
    components:
      produits.length > 0 ? [productCarousel(produits, motsCles)] : [],
  };
};

/**
 * Cherche, puis retire un mot et recommence.
 *
 * « souris sans fil noire Logitech » ne trouve rien quand « souris sans fil »
 * trouve cinq articles : chaque précision ajoutée éloigne la requête des noms
 * réellement présents au catalogue. Le modèle de vision, lui, ajoute volontiers
 * une précision de trop.
 *
 * On part donc du plus précis et on élague, plutôt que d'abandonner au
 * premier échec.
 */
async function chercherEnRaccourcissant(
  ctx: ToolContext,
  motsCles: string,
  pos: { lat: number; lng: number } | undefined,
): Promise<ReturnType<typeof versProductRow>[]> {
  const mots = motsCles.split(/\s+/).filter(Boolean);

  for (let n = mots.length; n >= 1; n--) {
    const requete = mots.slice(0, n).join(' ');
    const { data, error } = await ctx.db.rpc('search_products', {
      query_text: requete,
      query_embedding: null,
      origin_lat: pos?.lat ?? null,
      origin_lng: pos?.lng ?? null,
      radius_m: null,
      filter_category: null,
      match_count: null,
    });

    if (error) throw error;

    const produits = ((data ?? []) as Record<string, unknown>[]).map(versProductRow);
    if (produits.length > 0) return produits;
  }

  return [];
}

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

/**
 * La dernière commande en cours du client, ou une chaîne vide.
 *
 * Sans identifiant, « où est ma commande ? » et « annule » désignent la
 * même chose dans presque tous les cas : la dernière qui n'est ni livrée ni
 * annulée.
 */
async function commandeEnCours(ctx: ToolContext, fourni: string): Promise<string> {
  if (fourni) return fourni;

  const { data } = await ctx.db
    .from('orders')
    .select('id')
    .not('status', 'in', '("delivered","cancelled")')
    .order('placed_at', { ascending: false })
    .limit(1);

  return (data?.[0]?.id as string | undefined) ?? '';
}

/**
 * Annulation par le client.
 *
 * La décision appartient entièrement à la base : cancel_my_order vérifie
 * qu'aucun livreur n'est parti et que rien n'a été encaissé, puis renvoie un
 * motif lisible en cas de refus. Le modèle ne fait que le transmettre.
 *
 * S'il arbitrait lui-même, il finirait par annuler une commande déjà payée
 * parce que le client aura insisté — et l'argent serait perdu pour le
 * boutiquier.
 */
const annulerCommande: Executor = async (args, ctx) => {
  const orderId = await commandeEnCours(ctx, texte(args, 'order_id'));
  if (!orderId) return { summary: { commandes_en_cours: 0 }, components: [] };

  const { data, error } = await ctx.db.rpc('cancel_my_order', {
    p_order_id: orderId,
    p_motif: texte(args, 'motif') || null,
  });

  if (error) return { summary: { erreur: error.message }, components: [] };

  const refus = data as string | null;
  if (refus) return { summary: { annulee: false, raison: refus }, components: [] };

  // Le suivi remis à jour montre la commande annulée. Sans lui, l'ancienne
  // carte resterait à l'écran avec un statut périmé.
  const { data: suivi } = await ctx.db.rpc('order_tracking', { p_order_id: orderId });

  return {
    summary: { annulee: true, order_id: orderId },
    components: suivi ? [orderTracking(suivi as Record<string, unknown>)] : [],
  };
};

/**
 * De quoi appeler le livreur.
 *
 * Le numéro vient de order_tracking, qui ne le donne qu'aux personnes
 * concernées par la commande. On ne le lit jamais dans profiles : ce serait
 * exposer le téléphone d'un livreur à qui saurait le demander.
 */
const appelerLivreur: Executor = async (args, ctx) => {
  const orderId = await commandeEnCours(ctx, texte(args, 'order_id'));
  if (!orderId) return { summary: { commandes_en_cours: 0 }, components: [] };

  const { data } = await ctx.db.rpc('order_tracking', { p_order_id: orderId });
  if (!data) return { summary: { erreur: 'commande introuvable' }, components: [] };

  const suivi = data as Record<string, unknown>;
  const livreur = suivi['driver'] as { name?: string; phone?: string } | null;

  if (!livreur?.phone) {
    return {
      summary: { livreur_assigne: false, statut: suivi['status'] },
      components: [],
    };
  }

  return {
    summary: { livreur_assigne: true, nom: livreur.name ?? null },
    // La carte de suivi porte déjà le bouton d'appel : la renvoyer évite
    // d'inventer un composant pour un geste qui existe.
    components: [orderTracking(suivi)],
  };
};

const suivreCommande: Executor = async (args, ctx) => {
  const orderId = await commandeEnCours(ctx, texte(args, 'order_id'));

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
 * Le catalogue d'une boutique.
 *
 * Sans cet outil, le modèle n'avait aucun moyen d'honorer « montre-moi ce
 * que propose cette boutique » : il repliait sur `rechercher_produits` avec
 * l'identifiant comme texte, ne trouvait rien, et répondait qu'il n'avait
 * rien trouvé. Le client concluait que la boutique était vide.
 */
const produitsDeBoutique: Executor = async (args, ctx) => {
  const merchantId = texte(args, 'merchant_id');
  if (!merchantId) return { summary: { erreur: 'identifiant manquant' }, components: [] };

  const limite = Math.min(nombre(args, 'limite') ?? 12, 30);

  const { data: boutique } = await ctx.db
    .from('merchants')
    .select('name, is_open')
    .eq('id', merchantId)
    .maybeSingle();

  const { data } = await ctx.db
    .from('products')
    .select('id, name, description, image_url, price, is_available, merchant_id, merchants(name)')
    .eq('merchant_id', merchantId)
    .eq('is_available', true)
    .order('name')
    .limit(limite);

  const lignes = (data ?? []) as Array<Record<string, unknown>>;
  const nom = (boutique?.name as string | null) ?? 'Cette boutique';

  if (lignes.length === 0) {
    return { summary: { boutique: nom, produits: 0 }, components: [] };
  }

  const items = lignes.map((p) => ({
    id: p['id'] as string,
    name: p['name'] as string,
    description: (p['description'] as string | null) ?? null,
    image_url: (p['image_url'] as string | null) ?? null,
    price: p['price'] as number,
    is_available: p['is_available'] as boolean,
    merchant_id: p['merchant_id'] as string,
    merchant_name: (p['merchants'] as { name?: string } | null)?.name ?? null,
  }));

  return {
    summary: {
      boutique: nom,
      ouverte: boutique?.is_open ?? null,
      produits: items.map((i) => ({ id: i.id, nom: i.name, prix: i.price })),
    },
    components: [productCarousel(items, nom)],
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
          label: `Livrer à ${nommerAdresse(a)}`,
          value: `adresse:${a.id}`,
        })),
        { label: 'Ailleurs', value: 'adresse:nouvelle' },
      ]),
    ],
  };
};

/**
 * De quoi distinguer deux adresses sur un bouton.
 *
 * L'application enregistrait toute nouvelle adresse sous le libellé littéral
 * « Adresse ». Trois adresses donnaient donc trois boutons « Livrer à
 * Adresse » rigoureusement identiques : impossible de choisir, et le hasard
 * décidait où la commande était livrée.
 *
 * Quand le libellé ne dit rien, on prend le repère — c'est le client qui l'a
 * écrit, c'est donc lui qui lui parle. Tronqué au premier segment : « Yantala,
 * derrière la pharmacie Al Nour » ne tient pas dans un bouton, « Yantala » si.
 */
function nommerAdresse(a: { label: string; text_hint: string }): string {
  const libelle = (a.label ?? '').trim();
  const generique = libelle === '' || /^adresses?$/i.test(libelle);
  if (!generique) return libelle;

  const repere = (a.text_hint ?? '').trim();
  if (repere === '') return 'cette adresse';

  const premier = repere.split(/[,;·]/)[0]!.trim();
  const court = premier === '' ? repere : premier;
  return court.length > 24 ? `${court.slice(0, 23).trimEnd()}…` : court;
}

/**
 * Remet au panier une commande déjà livrée.
 *
 * Le bouton « Recommander » existait depuis longtemps et ne menait nulle
 * part : aucun outil ne traitait la valeur `recommander:<id>`. Le client
 * appuyait, rien ne se passait. Un bouton mort coûte plus cher qu'un bouton
 * absent — on essaie une fois, puis on cesse de croire au reste.
 *
 * Le travail est fait en base par `reorder_into_cart`, qui rappelle
 * `cart_add_item` ligne par ligne : mêmes contrôles de disponibilité, et
 * surtout PRIX DU JOUR. Recopier l'ancien prix ferait payer au boutiquier
 * un tarif d'avril.
 */
const recommanderCommande: Executor = async (args, ctx) => {
  const id = texte(args, 'commande_id');
  if (!id) return { summary: { erreur: 'identifiant manquant' }, components: [] };

  const { data, error } = await ctx.db.rpc('reorder_into_cart', { p_order_id: id });

  if (error) {
    // Conflit de boutique, plus rien de disponible : ces messages sont
    // rédigés pour le client. On les transmet au lieu de les reformuler.
    return { summary: { erreur: error.message }, components: [] };
  }

  const bilan = (data ?? {}) as { repris?: number; ignores?: string[] };
  const manquants = bilan.ignores ?? [];

  const panier = await panierCourant(ctx);

  return {
    summary: {
      repris: bilan.repris ?? 0,
      // Nommément. Le modèle doit pouvoir dire ce qui manque : un panier
      // amputé en silence ne se découvre qu'au moment de payer.
      ...(manquants.length > 0 ? { indisponibles: manquants } : {}),
      panier: panier.summary,
    },
    components: panier.components,
  };
};

const historiqueCommandes: Executor = async (args, ctx) => {
  const limite = Math.min(nombre(args, 'limite') ?? 5, 10);

  const { data } = await ctx.db
    .from('orders')
    // Les articles, et pas seulement le total : « Recommander (4500 F) » ne
    // rappelle à personne ce qu'il a mangé.
    .select('id, type, status, total, placed_at, dropoff_hint, order_items(product_name, quantity)')
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
        articles: ((o.order_items ?? []) as Array<{ product_name: string; quantity: number }>)
          .map((a) => `${a.quantity} × ${a.product_name}`),
      })),
    },
    components: [
      quickReplies(
        commandes.slice(0, 3).map((o) => {
          const a = (o.order_items ?? []) as Array<{ product_name: string; quantity: number }>;
          // Le premier article nomme la commande. Un bouton doit dire ce
          // qu'il fait, pas seulement combien il coûte.
          const titre = a.length === 0
            ? `${o.total} F`
            : a.length === 1
              ? a[0]!.product_name
              : `${a[0]!.product_name} +${a.length - 1}`;
          return { label: `Reprendre : ${titre}`, value: `recommander:${o.id}` };
        }),
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
        boutique: S.string(
          "Nom de la boutique, quand l'utilisateur en désigne une — « chez otakoss ». Écris-le tel qu'il l'a dit : la correspondance est tolérante aux apostrophes et aux capitales. N'APPELLE PAS boutiques_proches pour cela, elle ne cherche que par la géographie.",
        ),
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
    name: 'recommander_commande',
    description:
      "Remet au panier tous les articles d'une commande déjà livrée, aux prix du jour. À appeler quand l'utilisateur veut reprendre la même chose — y compris depuis un bouton dont la valeur commence par « recommander: », l'identifiant suit les deux points.",
    parameters: {
      type: 'object',
      properties: {
        commande_id: S.string('Identifiant de la commande à reprendre'),
      },
      required: ['commande_id'],
    },
  },
  {
    name: 'annuler_commande',
    description:
      "Annule une commande du client. Possible tant qu'aucun livreur n'est en " +
      "route, et si elle n'a pas déjà été payée. Sans identifiant, prend la " +
      "dernière commande en cours. N'arbitre jamais toi-même : l'outil refuse " +
      'et explique pourquoi quand il ne peut pas.',
    parameters: {
      type: 'object',
      properties: {
        order_id: S.string('Identifiant de commande'),
        motif: S.string('Raison donnée par le client, si elle est dite'),
      },
    },
  },
  {
    name: 'appeler_livreur',
    description:
      'Donne au client de quoi appeler le livreur de sa commande. Pour ' +
      "« appelle le livreur », « je veux lui parler ». Ne donne rien tant " +
      "qu'aucun livreur n'est assigné.",
    parameters: {
      type: 'object',
      properties: { order_id: S.string('Identifiant de commande') },
    },
  },
  {
    name: 'produits_de_boutique',
    description:
      "Le catalogue d'une boutique précise. À utiliser dès qu'on parle d'une " +
      "boutique identifiée — après boutiques_proches, ou quand le client la " +
      "nomme. Ne jamais chercher une boutique par son identifiant avec " +
      'rechercher_produits : cet outil-là cherche des PRODUITS.',
    parameters: {
      type: 'object',
      properties: {
        merchant_id: S.string('Identifiant de la boutique'),
        limite: S.number('Nombre de produits, 12 par défaut'),
      },
      required: ['merchant_id'],
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
  recommander_commande: recommanderCommande,
  annuler_commande: annulerCommande,
  appeler_livreur: appelerLivreur,
  produits_de_boutique: produitsDeBoutique,
  mes_adresses: mesAdresses,
  preparer_course: preparerCourse,
};
