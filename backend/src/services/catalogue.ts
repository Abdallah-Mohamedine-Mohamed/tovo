import type { SupabaseClient } from '@supabase/supabase-js';
import { boutiquesCorrespondantes, boutiquesMentionnees, demandeBoutiqueOuverte, normaliserIntention, nomBoutiqueApresMarqueur, requeteProduitUtilisateur } from '../ai/intents.js';
import { categoryGrid, merchantCard, productCarousel, type Component, type MerchantRow, type ProductRow } from '../components/builders.js';
import { embed, embeddingsEnabled } from './embeddings.js';

export interface CataloguePage {
  items: ProductRow[];
  total: number;
  offset: number;
  next_offset: number | null;
  match_type: 'exact' | 'similar';
  category_id?: string | undefined;
}

export interface CatalogueFilter {
  q?: string | undefined;
  merchant_ids?: string[] | undefined;
  category_id?: string | undefined;
  offset?: number | undefined;
  limit?: number | undefined;
}

export interface CatalogueIntent {
  merchants: MerchantRow[];
  query: string;
  menu: boolean;
  openOnly?: boolean;
  noneOpen?: boolean;
  missing?: string;
}

export interface PendingMerchantChoice {
  merchant_ids: string[];
  query: string;
}

const MOTS_SIMILAIRES_VIDES = new Set([
  'avec', 'chez', 'dans', 'pour', 'sans', 'sur', 'tout', 'toute', 'tous', 'toutes',
]);

function motsRecherche(texte: string): string[] {
  return requeteProduitUtilisateur(texte)
    .split(' ')
    .map((mot) => mot.replace(/s$/, ''))
    .filter((mot) => mot.length >= 3 && !MOTS_SIMILAIRES_VIDES.has(mot));
}

/**
 * Un vecteur ne suffit jamais à prouver qu'un produit répond à la demande.
 * Il sert à classer des candidats, puis les mots du catalogue doivent encore
 * confirmer l'objet. C'est ce qui interdit « thé au lait » pour « pommade ».
 */
export function filtrerSuggestionsTextuelles(query: string, items: ProductRow[]): ProductRow[] {
  const demandes = [...new Set(motsRecherche(query))];
  if (demandes.length === 0) return [];

  return items.filter((item) => {
    const disponibles = new Set(motsRecherche(`${item.name} ${item.description ?? ''}`));
    const correspondances = demandes.filter((mot) => disponibles.has(mot));
    if (demandes.length === 1) return correspondances.length === 1;

    const pivots = demandes.slice(0, Math.min(2, demandes.length));
    const pivotsRequis = demandes.length >= 4 ? pivots.length : 1;
    const pivotsTrouves = pivots.filter((mot) => disponibles.has(mot)).length;
    return correspondances.length >= Math.min(2, demandes.length)
      && pivotsTrouves >= pivotsRequis;
  });
}

// Les mots d'une QUESTION sur la boutique (« qu'est-ce que … a comme
// produit ? ») comptent aussi : restés dans la requête, ils devenaient la
// recherche de « qu est comme » chez Garba d'Or.
const MENU_WORDS = new Set('je j veux voudrais souhaite aimerais peux pourrais voir consulter regarder manger commander prendre acheter montre montrez donne donnez moi la le les de du des d chez a au en carte menu menus produit produits article articles plat plats propose proposes proposer proposez boutique restaurant resto enseigne tous toutes tout toute un une svp merci ce que qu est quoi quel quelle quels quelles comme il y avez as vous ont avoir vend vendez vendent quoi'.split(' '));

/** Les mots qui décrivent le commerce sans le nommer. */
const MOTS_GENERIQUES_ENSEIGNE = new Set(['restaurant', 'restau', 'resto', 'boutique', 'supermarche', 'magasin', 'chez', 'le', 'la', 'les', 'l', 'd', 'de', 'du', 'des', 'et']);

export function requeteSansEnseigne(message: string, merchants: Array<{ id: string; name: string }>): string {
  const words = normaliserIntention(message).split(' ');
  const markerIndex = words.findIndex((word) => ['chez', 'boutique', 'enseigne', 'restaurant', 'resto'].includes(word));
  // Le nom complet, sans parenthèses, et son CŒUR sans les mots génériques :
  // « RESTAURANT AFC » se dit « AFC ». Sans ce cœur, « AFC » restait dans la
  // requête, cherché comme un PRODUIT chez AFC — « Je ne trouve pas de afc ».
  const aliases = merchants.flatMap((merchant) => {
    const sansParentheses = merchant.name.replace(/\([^)]*\)/g, '').trim();
    const coeur = normaliserIntention(sansParentheses).split(' ')
      .filter((mot) => mot && !MOTS_GENERIQUES_ENSEIGNE.has(mot)).join(' ');
    return [merchant.name, sansParentheses, ...(coeur ? [coeur] : [])];
  });
  let best: { start: number; length: number } | undefined;
  for (let start = 0; start < words.length; start++) {
    if (markerIndex >= 0 && start <= markerIndex) continue;
    for (let length = words.length - start; length > 0; length--) {
      const phrase = words.slice(start, start + length).join(' ');
      const compact = phrase.replace(/ /g, '');
      if (compact.length < 3) continue;
      const exact = aliases.some((alias) => normaliserIntention(alias).replace(/ /g, '') === compact);
      // Trois lettres (« AFC ») : seulement à l'identique. Au-delà, les
      // petites fautes sont tolérées.
      const fuzzy = compact.length >= 4 && aliases.some((alias) => {
        const normalized = normaliserIntention(alias).replace(/ /g, '');
        return Math.abs(compact.length - normalized.length) <= 2
          && boutiquesCorrespondantes(phrase, [{ id: 'candidate', name: alias }]).length > 0;
      });
      if ((exact || fuzzy) && (!best || length > best.length)) best = { start, length };
    }
  }
  if (!best) return message;
  // Le nom retiré PARTOUT : à l'oral on le répète (« … à Garbador.
  // Qu'est-ce que Garbador a… »), et la seconde fois restait dans la requête.
  // … mais seulement le nom de la boutique RECONNUE dans la phrase : retirer
  // ceux de toutes les boutiques effaçait « poulet » d'un « tacos poulet chez
  // Otakoss » s'il existait aussi une boutique POULET.
  const reconnue = words.slice(best.start, best.start + best.length).join(' ');
  const nomsColles = new Set(aliases
    .filter((alias) => normaliserIntention(alias).replace(/ /g, '') === reconnue.replace(/ /g, '')
      || boutiquesCorrespondantes(reconnue, [{ id: 'candidate', name: alias }]).length > 0)
    .map((alias) => normaliserIntention(alias).replace(/ /g, '')));
  return words.filter((word, index) => (index < best.start || index >= best.start + best.length)
    && !nomsColles.has(word) && !MENU_WORDS.has(word)).join(' ');
}

export async function cataloguePage(db: SupabaseClient, filter: CatalogueFilter, semantic = true): Promise<CataloguePage> {
  const query = requeteProduitUtilisateur(filter.q ?? '');
  const parameters = {
    p_query: query, p_embedding: null as string | null,
    p_merchants: filter.merchant_ids ?? null, p_category: filter.category_id ?? null,
    p_offset: filter.offset ?? 0, p_limit: filter.limit ?? 24,
  };
  let response = await db.rpc('catalog_products_page', parameters);
  if (response.error) throw response.error;
  let page = response.data as CataloguePage;
  if (page.total === 0 && parameters.p_query) {
    const normalizedQuery = normaliserIntention(parameters.p_query);
    const singleWord = normalizedQuery.length > 0 && !normalizedQuery.includes(' ');
    if (!parameters.p_category && singleWord) {
      const { data: categories, error } = await db.from('categories')
        .select('id, name').eq('is_active', true).limit(500);
      if (error) throw error;
      const singular = (word: string) => word.replace(/s$/, '');
      const matches = (categories ?? []).filter((category) =>
        normaliserIntention(category.name as string).split(' ').some((word) => singular(word) === singular(normalizedQuery)));
      const exact = matches.filter((category) => singular(normaliserIntention(category.name as string)) === singular(normalizedQuery));
      const category = exact.length === 1 ? exact[0] : matches.length === 1 ? matches[0] : undefined;
      if (category) parameters.p_category = category.id as string;
    }
    if (parameters.p_category) {
      response = await db.rpc('catalog_products_page', { ...parameters, p_query: '', p_embedding: null });
      if (response.error) throw response.error;
      page = response.data as CataloguePage;
      page.category_id = parameters.p_category;
      return page;
    }
    const vector = semantic && embeddingsEnabled && !singleWord
      ? await embed(parameters.p_query, 'query').catch(() => null) : null;
    if (vector) {
      response = await db.rpc('catalog_products_page', { ...parameters, p_embedding: JSON.stringify(vector) });
      if (response.error) throw response.error;
      page = response.data as CataloguePage;
      if (page.match_type === 'similar') {
        const items = filtrerSuggestionsTextuelles(parameters.p_query, page.items);
        page = { ...page, items, total: items.length, next_offset: null };
      }
    }
  }
  if (parameters.p_category && !filter.category_id) page.category_id = parameters.p_category;
  return page;
}

const COLONNES_ENSEIGNE = 'id, name, description, logo_url, address_hint, is_open, rating, prep_time_min';

/**
 * Chaque enseigne, plus une entrée par variante connue (« otacos » pour
 * O'Takoss, migration 0056) : le rapprochement de noms les essaie toutes.
 * `retrouver` ramène ensuite chaque entrée à la vraie fiche, sans doublon.
 */
function avecVariantes(catalogue: Array<MerchantRow & { search_aliases?: string | null }>): MerchantRow[] {
  return catalogue.flatMap((m) => [
    m,
    ...String(m.search_aliases ?? '').split(/[;,\n]/).map((v) => v.trim()).filter((v) => v.length >= 3)
      .map((name) => ({ ...m, name })),
  ]);
}
function retrouver(trouvees: MerchantRow[], catalogue: MerchantRow[]): MerchantRow[] {
  const ids = [...new Set(trouvees.map((m) => m.id))];
  return ids.flatMap((id) => catalogue.filter((m) => m.id === id).slice(0, 1));
}

/**
 * Les enseignes approuvées, gardées en mémoire quelques instants.
 *
 * Elles étaient relues en entier depuis la base à CHAQUE message — un aller-
 * retour réseau sur le chemin de toutes les réponses, pour une liste qui
 * change quelques fois par jour. Données publiques (identiques pour tous les
 * clients) : les partager entre requêtes ne révèle rien.
 *
 * 30 s de fraîcheur : une enseigne qui ouvre ou ferme le voit au plus tard
 * trente secondes après ; `is_open` n'y décide de toute façon rien seul
 * (merchant_open_now fait foi au moment de chercher).
 */
const ENSEIGNES_TTL_MS = 30_000;
let enseignesEnCache: { quand: number; liste: Array<MerchantRow & { search_aliases?: string | null }> } | null = null;

/** Réservé aux tests : oublie la liste gardée en mémoire. */
export function oublierEnseignes(): void {
  enseignesEnCache = null;
}

async function enseignesApprouvees(db: SupabaseClient): Promise<Array<MerchantRow & { search_aliases?: string | null }>> {
  if (enseignesEnCache && Date.now() - enseignesEnCache.quand < ENSEIGNES_TTL_MS) return enseignesEnCache.liste;
  const catalogue: Array<MerchantRow & { search_aliases?: string | null }> = [];
  // Avec les variantes si la migration 0056 est passée, sans sinon : la
  // reconnaissance des enseignes ne doit jamais tomber pour une colonne.
  let colonnes = `${COLONNES_ENSEIGNE}, search_aliases`;
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await db.from('merchants')
      .select(colonnes)
      .eq('is_approved', true).order('id').range(offset, offset + 499);
    if (error?.code === '42703' && colonnes !== COLONNES_ENSEIGNE) { colonnes = COLONNES_ENSEIGNE; offset -= 500; continue; }
    if (error) throw error;
    catalogue.push(...(data ?? []) as unknown as MerchantRow[]);
    if ((data?.length ?? 0) < 500) break;
  }
  enseignesEnCache = { quand: Date.now(), liste: catalogue };
  return catalogue;
}

export async function resolveCatalogueIntent(db: SupabaseClient, message: string, pending?: PendingMerchantChoice): Promise<CatalogueIntent> {
  const catalogue = await enseignesApprouvees(db);
  const variantes = avecVariantes(catalogue);
  const marker = nomBoutiqueApresMarqueur(message);
  const openOnly = demandeBoutiqueOuverte(message);
  const productQuery = normaliserIntention(message).split(' ').filter((word) => !MENU_WORDS.has(word)).join(' ');
  let candidates = retrouver(marker
    ? boutiquesCorrespondantes(marker, variantes)
    : boutiquesMentionnees(message, variantes), catalogue);
  if (!marker && candidates.length === 0 && productQuery) {
    candidates = retrouver(boutiquesCorrespondantes(productQuery, variantes), catalogue);
  }
  if (!marker && pending && normaliserIntention(message).split(' ').length <= 4) {
    const offered = pending.merchant_ids.flatMap((id) => catalogue.filter((merchant) => merchant.id === id));
    const ordinal = /^(le )?(premier|1|1er)$/.test(normaliserIntention(message)) ? 0
      : /^(le )?(deuxieme|second|2|2e)$/.test(normaliserIntention(message)) ? 1 : -1;
    const selected = ordinal >= 0 ? offered.slice(ordinal, ordinal + 1) : boutiquesCorrespondantes(message, offered);
    if (selected.length === 1 && (candidates.length === 0 || candidates[0]?.id === selected[0]?.id)) {
      return { merchants: selected, query: pending.query, menu: pending.query.length === 0 };
    }
  }
  if (candidates.length === 0) {
    return { merchants: [], query: message, menu: false, ...(marker ? { missing: marker } : {}) };
  }
  if (!marker) {
    const exactProducts = productQuery ? await cataloguePage(db, { q: productQuery, limit: 1 }, false) : null;
    // Un produit ne l'emporte sur une boutique reconnue que s'il correspond
    // EXACTEMENT. Les « suggestions proches » de la recherche tolérante
    // (« Garba », « Garba Poisson ») faisaient passer « Garbador » — Garba
    // d'Or dit à voix haute — pour une recherche de produit.
    if (exactProducts && exactProducts.total > 0 && exactProducts.match_type !== 'similar') {
      return { merchants: [], query: message, menu: false };
    }
  }
  if (openOnly) {
    const opened = candidates.filter((merchant) => merchant.is_open);
    return { merchants: opened.length > 0 ? opened : candidates, query: '', menu: true,
      openOnly: true, ...(opened.length === 0 ? { noneOpen: true } : {}) };
  }
  const query = requeteSansEnseigne(message, candidates);
  return { merchants: candidates, query, menu: query.length === 0 };
}

export interface CatalogueAnswer {
  content: string;
  summary: Record<string, unknown>;
  components: Component[];
}

export async function merchantMenu(db: SupabaseClient, merchantId: string): Promise<CatalogueAnswer> {
  const { data: merchant, error } = await db.from('merchants')
    .select('id, name, description, logo_url, address_hint, is_open, rating, prep_time_min')
    .eq('id', merchantId).eq('is_approved', true).maybeSingle();
  if (error) throw error;
  if (!merchant) return { content: 'Cette boutique est indisponible.', summary: { resultats: 0 }, components: [] };
  const { data: sections, error: sectionError } = await db.rpc('merchant_categories', { p_merchant_id: merchantId });
  if (sectionError) throw sectionError;
  const page = await cataloguePage(db, { merchant_ids: [merchantId], limit: 8 });
  const categories = (sections ?? []).map((section: Record<string, unknown>) => ({
    id: section.id as string, name: section.name as string, icon: section.icon as string | null,
    image_url: section.image_url as string | null, merchant_id: merchantId, produits: Number(section.produits),
  }));
  const merchantComponent = merchantCard(merchant as MerchantRow);
  merchantComponent.data.total_products = page.total;
  const categoryComponent = categoryGrid(categories, 'La carte');
  categoryComponent.data.collapse_in_chat = true;
  return {
    content: `La carte de **${merchant.name}** : **${page.total} produits**. Ouvrez la boutique pour les parcourir${categories.length > 1 ? ' par catégorie' : ''}.`,
    summary: { boutique: merchant.name, merchant_id: merchantId, total: page.total, categories },
    components: [merchantComponent, ...(categories.length > 1
      ? [categoryComponent]
      : page.items.length > 0 ? [productCarousel(page.items, merchant.name as string, {
        merchant_id: merchantId, total: page.total,
      })] : [])],
  };
}

export async function merchantIntentAnswer(db: SupabaseClient, intent: CatalogueIntent): Promise<CatalogueAnswer | null> {
  if (intent.missing) return {
    content: `Je ne trouve pas l’enseigne **${intent.missing}**. Pouvez-vous préciser son nom ?`,
    summary: { boutique_introuvable: intent.missing }, components: [],
  };
  if (intent.noneOpen) return {
    content: "Aucune adresse de cette enseigne n'est ouverte en ce moment.",
    summary: { boutiques_ouvertes: 0 },
    components: intent.merchants.map(merchantCard),
  };
  if (intent.merchants.length > 1) return {
    content: intent.openOnly
      ? 'Voici les adresses ouvertes de cette enseigne. Laquelle choisissez-vous ?'
      : 'Quelle adresse choisissez-vous ? Voici les établissements de cette enseigne.',
    summary: { choix_enseigne_requis: true, boutiques: intent.merchants.map(({ id, name }) => ({ id, nom: name })) },
    components: intent.merchants.map((merchant) => {
      const card = merchantCard(merchant);
      return { ...card, data: { ...card.data, pending_query: intent.query, choose_branch: true } };
    }),
  };
  if (intent.openOnly && intent.merchants[0]) return {
    content: `**${intent.merchants[0].name}** est ouverte en ce moment.`,
    summary: { boutiques_ouvertes: 1, boutique: intent.merchants[0].name },
    components: [merchantCard(intent.merchants[0])],
  };
  if (intent.menu && intent.merchants[0]) return merchantMenu(db, intent.merchants[0].id);
  return null;
}

export function searchAnswer(page: CataloguePage, filter: CatalogueFilter): CatalogueAnswer {
  const query = filter.q ?? '';
  const similar = page.match_type === 'similar';
  const preview = page.items.slice(0, 8);
  const mots = query.split(' ').filter(Boolean);
  // Une longue phrase qui ramène des centaines de produits n'a pas été
  // comprise : chaque mot, pris seul, trouve quelque chose. Annoncer
  // « 1278 produits correspondent » à « bon l ukounou me reserves bon coin »
  // était faux. Mieux vaut le dire, et demander le nom du produit.
  if (mots.length >= 4 && page.total > 150) {
    return {
      content: 'Je n’ai pas bien compris ce que vous cherchez. Pouvez-vous me redire le nom du produit ?',
      summary: { incompris: true, requete: query },
      components: [],
    };
  }
  // En titre, quelques mots propres, jamais la phrase entière.
  const titre = mots.length <= 3 ? query : '';
  return {
    content: page.total === 0
      ? query
        ? `Je ne trouve pas de **${query}** disponible sur Tovo pour le moment.`
        : 'Aucun produit disponible pour le moment.'
      : similar ? 'Voici des suggestions proches de votre demande. Vous pouvez parcourir les résultats.'
      : `**${page.total} produits** correspondent à votre recherche. Vous pouvez parcourir les résultats et choisir votre enseigne.`,
    summary: { total: page.total, affiches: preview.length, suggestions: similar,
      produits: preview.map((product) => ({ id: product.id, nom: product.name, prix: product.price, boutique: product.merchant_name, a_personnaliser: product.requires_options ?? false })),
      consigne: 'Le carrousel est un aperçu. Le total concerne tous les résultats accessibles dans le catalogue.' },
    components: preview.length ? [productCarousel(preview, titre, {
      query, total: page.total, merchant_ids: filter.merchant_ids, category_id: page.category_id ?? filter.category_id,
    })] : [],
  };
}
