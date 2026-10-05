import type { SupabaseClient } from '@supabase/supabase-js';
import { boutiquesCorrespondantes, boutiquesMentionnees, demandeBoutiqueOuverte, normaliserIntention, nomBoutiqueApresMarqueur, requeteProduitUtilisateur } from '../ai/intents.js';
import { categoryGrid, merchantCard, productCarousel, quickReplies, type Component, type MerchantRow, type ProductRow } from '../components/builders.js';
import { embed, embeddingsEnabled } from './embeddings.js';
import { commandesRecentes, marquerLePlusCommande, parPopularite } from './popularite.js';
import { offreVille } from './livreur.js';
import { serviceClient } from './supabase.js';
import { carteCommerces, commercesDuType, commercesNommes, memeCommerce, commercesPourProduit, libelleDes, specialistesDe, type Commerce, type TypeCommerce } from './commerces.js';
import { avecOuvertureReelle } from './ouverture.js';
import { chercherSurGoogle, lieuGoogle, NOTE_GOOGLE } from './googlePlaces.js';
import { heuresDeGarde, reponseGarde } from './pharmaciesGarde.js';
import { paiementMobileActif } from '../config/env.js';
import { RAYON_DU_COMMERCE, SLUG_DU_RAYON, type Rayon, type TypeCommerceCherche } from '../ai/decideur.js';

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

/**
 * Les mesures et les emballages : ce qu'un produit PÈSE ou CONTIENT, jamais ce
 * que le client cherche. Une faute de frappe ne doit pas y mener : « livre »
 * (le livre) est à une lettre de « litre », et la recherche tolérante (0058)
 * renvoyait tout ce qui se vend au litre — 5Alive, l'eau, l'huile, un four
 * de 20 L (26/09).
 */
const MOTS_DE_MESURE = new Set([
  'l', 'litre', 'litres', 'cl', 'ml', 'kg', 'kilo', 'kilos', 'kilogramme', 'g', 'gr', 'gramme', 'grammes',
  'carton', 'cartons', 'sachet', 'sachets', 'bouteille', 'bouteilles', 'paquet', 'paquets', 'pack', 'packs',
  'boite', 'boites', 'bidon', 'bidons', 'flacon', 'flacons', 'canette', 'canettes', 'piece', 'pieces',
  'portion', 'portions', 'lot', 'lots', 'unite', 'unites', 'dose', 'doses',
]);

function distance(a: string, b: string): number {
  const ligne = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let precedent = ligne[0]!;
    ligne[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const courant = ligne[j]!;
      ligne[j] = Math.min(ligne[j]! + 1, ligne[j - 1]! + 1, precedent + (a[i - 1] === b[j - 1] ? 0 : 1));
      precedent = courant;
    }
  }
  return ligne[b.length]!;
}

/** Un mot du produit est-il assez proche du mot cherché ? Mêmes règles que 0058. */
function motProche(demande: string, mot: string): boolean {
  if (mot === demande) return true;
  if (MOTS_DE_MESURE.has(mot)) return false;
  if (mot[0] !== demande[0] || Math.abs(mot.length - demande.length) > 2) return false;
  const tolerance = demande.length <= 3 ? 0 : demande.length <= 5 ? 1 : 2;
  return distance(demande, mot) <= tolerance;
}

/**
 * Les suggestions « proches » (fautes de frappe) ne sont gardées que si
 * chaque mot cherché ressemble à un VRAI mot du produit — pas à une mesure
 * ni à un emballage. Sinon, mieux vaut dire « je ne trouve pas ».
 */
export function filtrerSuggestionsProches(query: string, items: ProductRow[]): ProductRow[] {
  const demandes = [...new Set(motsRecherche(query))];
  if (demandes.length === 0) return items;
  return items.filter((item) => {
    const mots = motsRecherche(`${item.name} ${item.description ?? ''}`);
    return demandes.every((d) => mots.some((m) => motProche(d, m)));
  });
}

// Les mots d'une QUESTION sur la boutique (« qu'est-ce que … a comme
// produit ? ») comptent aussi : restés dans la requête, ils devenaient la
// recherche de « qu est comme » chez Garba d'Or.
const MENU_WORDS = new Set(('je j veux voudrais souhaite aimerais peux pourrais voir consulter regarder manger commander prendre acheter montre montrez donne donnez moi la le les de du des d chez a au en carte menu menus produit produits article articles plat plats propose proposes proposer proposez boutique restaurant resto enseigne tous toutes tout toute un une svp merci ce que qu est quoi quel quelle quels quelles comme il y avez as vous ont avoir vend vendez vendent quoi '
  // « Je VAIS manger chez O'TAKOSS » : « vais » restait seul, pris pour le
  // produit cherché, et la carte s'ouvrait filtrée sur « vais » — aucun
  // résultat — au lieu de la page de l'enseigne (26/09).
  + 'vais vas va allons allez vont aller irai ira passer passe faire fais bouffer boire diner dejeuner '
  + 'aime ai envie faim ma mon mes ici aujourd hui soir midi maintenant juste aussi encore bien').split(' '));

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

/**
 * Une page du catalogue, et ce que les autres commandent (services/
 * popularite.ts) — sans jamais un chiffre. Chez UNE enseigne, ses produits
 * les plus commandés remontent en tête. Partout, le plus commandé de la liste
 * est marqué (`plus_commande`) ; une recherche générale garde son ordre de
 * pertinence.
 */
export async function cataloguePage(db: SupabaseClient, filter: CatalogueFilter, semantic = true): Promise<CataloguePage> {
  const [page, parProduit] = await Promise.all([cataloguePageBrute(db, filter, semantic), commandesRecentes()]);
  if (parProduit.size === 0) return page;
  const uneEnseigne = filter.merchant_ids?.length === 1;
  const items = uneEnseigne ? parPopularite(page.items, parProduit) : page.items;
  return { ...page, items: marquerLePlusCommande(items, parProduit) };
}

async function cataloguePageBrute(db: SupabaseClient, filter: CatalogueFilter, semantic = true): Promise<CataloguePage> {
  const query = requeteProduitUtilisateur(filter.q ?? '');
  const parameters = {
    p_query: query, p_embedding: null as string | null,
    p_merchants: filter.merchant_ids ?? null, p_category: filter.category_id ?? null,
    p_offset: filter.offset ?? 0, p_limit: filter.limit ?? 24,
  };
  let response = await db.rpc('catalog_products_page', parameters);
  if (response.error) throw response.error;
  let page = response.data as CataloguePage;
  // Des suggestions par faute de frappe : on vérifie qu'elles ressemblent
  // vraiment à la demande (et pas seulement à « litre »).
  if (page.match_type === 'similar' && parameters.p_query && page.total > 0) {
    const items = filtrerSuggestionsProches(parameters.p_query, page.items);
    page = { ...page, items, total: items.length, next_offset: null };
  }
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
    // Seulement une catégorie NOMMÉE par le client (« boissons »). Un rayon
    // imposé (le cerveau) sans correspondance n'affiche pas tout le rayon :
    // « montre » donnait les 59 vêtements, « paracétamol » la parapharmacie.
    if (parameters.p_category && parameters.p_category !== filter.category_id) {
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

/**
 * L'identifiant de la catégorie racine d'un rayon (« supermarche » →
 * Supermarché), gardé en mémoire : la recherche s'y limite, sous-rayons
 * compris (catalog_products_page, categories_scope).
 */
const idsDesRayons = new Map<string, string | null>();
export async function idDuRayon(db: SupabaseClient, rayon: Rayon): Promise<string | undefined> {
  const slug = SLUG_DU_RAYON[rayon];
  if (!idsDesRayons.has(slug)) {
    const { data, error } = await db.from('categories').select('id').eq('slug', slug).eq('is_active', true).maybeSingle();
    // Une panne passagère n'est pas une absence : rien n'est mémorisé, on
    // relira au prochain message (sinon le rayon restait perdu jusqu'au
    // redémarrage — évaluation externe, 02/10).
    if (error) return undefined;
    idsDesRayons.set(slug, (data?.id as string | undefined) ?? null);
  }
  return idsDesRayons.get(slug) ?? undefined;
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

/**
 * Plusieurs agences d'une enseigne, et le client en a nommé une (« Otakoss
 * centre aéré ») : on garde celle-là. Les variantes communes (« OTAKOSS »)
 * trouvaient les deux, et Tovo redemandait l'agence que le client venait de
 * dire (examen du 02/10). Seuls comptent les mots PROPRES au nom d'une agence
 * (« centre », « aere » ; « nouveau », « marche ») — jamais les variantes,
 * qui ne distinguent rien.
 */
export function agenceNommee<T extends { id: string; name: string }>(message: string, candidates: T[]): T[] {
  if (candidates.length < 2) return candidates;
  const mots = (texte: string) => new Set(normaliserIntention(texte).split(' ').filter((m) => m.length >= 3));
  const dansLeMessage = mots(message);
  const nomsDe = candidates.map((c) => mots(c.name));
  const scores = nomsDe.map((nom, i) => [...nom]
    .filter((m) => nomsDe.every((autre, j) => j === i || !autre.has(m)))
    .filter((m) => dansLeMessage.has(m)).length);
  const meilleur = Math.max(...scores);
  if (meilleur === 0) return candidates;
  return candidates.filter((_, i) => scores[i] === meilleur);
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
  candidates = agenceNommee(message, candidates);
  if (!marker && pending && normaliserIntention(message).split(' ').length <= 4) {
    const offered = pending.merchant_ids.flatMap((id) => catalogue.filter((merchant) => merchant.id === id));
    const ordinal = /^(le )?(premier|1|1er)$/.test(normaliserIntention(message)) ? 0
      : /^(le )?(deuxieme|second|2|2e)$/.test(normaliserIntention(message)) ? 1 : -1;
    // Article 2 de la constitution : ce qui attend une réponse donne le sens.
    // « centre aéré » après « Centre Aéré ou Nouveau Marché ? » désigne l'une
    // des adresses PROPOSÉES — pas les autres boutiques « du Centre Aéré »
    // (Boba, Baaklini…), qui l'emportaient (02/10).
    const parSesMots = agenceNommee(message, offered);
    const selected = ordinal >= 0 ? offered.slice(ordinal, ordinal + 1)
      : parSesMots.length === 1 ? parSesMots : boutiquesCorrespondantes(message, offered);
    if (selected.length === 1) {
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

const MARQUEUR_ENSEIGNE = /\b(?:chez|boutique|enseigne|restaurant|resto)\b/gi;

/**
 * Le nom de l'enseigne tel que le client l'a écrit (« Tchos », pas « tchos ») :
 * ce qui suit le dernier « chez », sans la ponctuation finale.
 */
export function enseigneTelleQueDite(message: string, normalise: string): string {
  const marqueurs = [...message.matchAll(MARQUEUR_ENSEIGNE)];
  const dernier = marqueurs.at(-1);
  const suite = dernier ? message.slice(dernier.index + dernier[0].length) : '';
  const mots = suite.trim().split(/\s+/).slice(0, normalise.split(' ').length).join(' ');
  return mots.replace(/[.,;:!?…]+$/, '').trim() || normalise;
}

// Le début d'une demande, qui n'est pas l'article : « Je veux commander »,
// « J'aimerais avoir », « Donne-moi ».
const DEBUT_DE_DEMANDE = new Set(('je j veux voudrais souhaite aimerais peux pourrais voulais '
  + 'commander prendre acheter avoir manger boire trouver chercher cherche cherchons trouve ou est '
  + 'donne donnez apporte apportez il faut ai besoin veut voudrait y a t vous avez as tu '
  + 'moi me m svp stp bonjour bonsoir salut alors bon ok oui aussi encore').split(' '));
const DETERMINANT = /^(?:du|de|des|d|un|une|le|la|les|l|mon|ma|mes|deux|trois|quatre|cinq|\d+)$/;

/**
 * Ce que le client veut acheter, tel qu'il l'a dit, avant « chez » :
 * « Je veux commander de la viande » → « de la viande » (le déterminant est
 * gardé : il fait la phrase), « tacos poulet » → « tacos poulet ».
 */
export function articleAvantEnseigne(message: string): string {
  const mots = (message.split(MARQUEUR_ENSEIGNE)[0] ?? '').trim().split(/\s+/).filter(Boolean);
  let debut = 0;
  while (debut < mots.length && normaliserIntention(mots[debut]!).split(' ').every((m) => !m || DEBUT_DE_DEMANDE.has(m))) debut++;
  return mots.slice(debut).join(' ').replace(/[.,;:!?…]+$/, '').trim();
}

/** « de la viande » → « viande » : ce qu'on cherche dans le catalogue. */
function sansDeterminant(article: string): string {
  const mots = article.split(/\s+/);
  let i = 0;
  while (i < mots.length - 1 && normaliserIntention(mots[i]!).split(' ').every((m) => DETERMINANT.test(m))) i++;
  return mots.slice(i).join(' ');
}

/**
 * Note la boutique demandée (migration 0072) : l'admin voit les plus
 * réclamées, c'est la liste de prospection. Sans attendre, et sans jamais
 * faire échouer la réponse au client (table absente, réseau…).
 */
function noterBoutiqueDemandee(
  nom: string,
  article: string,
  trouvee: 'annuaire' | 'google' | 'inconnue',
  googlePlaceId?: string,
): void {
  const ligne = {
    nom: nom.slice(0, 120),
    nom_normalise: normaliserIntention(nom).slice(0, 120) || nom.toLowerCase().slice(0, 120),
    article: article.slice(0, 200) || null,
  };
  try {
    const table = serviceClient().from('boutiques_demandees');
    void Promise.resolve(table.insert({ ...ligne, trouvee, google_place_id: googlePlaceId ?? null }))
      // Migration 0073 pas encore appliquée : la demande est notée quand même.
      .then((r) => (r?.error ? table.insert(ligne) : r))
      .catch(() => undefined);
  } catch {
    // Jamais bloquant.
  }
}

/**
 * Le complément Google : l'identifiant Google déjà trouvé pour ce nom, s'il
 * existe (redemandé directement), sinon une recherche. Rien d'autre n'est lu
 * ni gardé de Google.
 */
async function trouverSurGoogle(nom: string): Promise<Array<Commerce & { place_id: string }>> {
  try {
    const { data } = await serviceClient().from('boutiques_demandees').select('google_place_id, trouvee, cree_le')
      .eq('nom_normalise', normaliserIntention(nom)).in('trouvee', ['google', 'inconnue'])
      .order('cree_le', { ascending: false }).limit(1).maybeSingle();
    const derniere = data as { google_place_id?: string | null; trouvee?: string; cree_le?: string } | null;
    if (derniere?.google_place_id) {
      const lieu = await lieuGoogle(derniere.google_place_id, nom);
      if (lieu) return [lieu];
    }
    // Google ne la connaissait pas il y a moins de 7 jours : chaque recherche
    // est facturée, même sans résultat — on ne redemande pas.
    if (derniere?.trouvee === 'inconnue' && derniere.cree_le
      && Date.now() - new Date(derniere.cree_le).getTime() < 7 * 86_400_000) return [];
  } catch {
    // Table ou colonne absente : on cherche, simplement.
  }
  return chercherSurGoogle(nom);
}

/** Les deux tuiles de la question « un livreur va l'acheter ? ». */
export const HORS_TOVO_OUI = 'hors-tovo-oui:';
export const HORS_TOVO_NON = 'hors-tovo-non:';
const SEP = '|';
const propre = (s: string) => s.replaceAll(SEP, ' ').slice(0, 120);

/**
 * Une enseigne que Tovo ne connaît pas (« de la viande chez Tchos ») : le
 * client veut CE produit-là, pas un autre. Plutôt que « Je ne trouve pas
 * l'enseigne », on lui DEMANDE si un livreur doit aller l'acheter. Le livreur
 * APPELLE le client pour convenir de l'achat (décision D6 du 02/10 : plus de
 * promesse d'avance, aucune règle figée de plafond ou de preuve — le fondateur
 * la garde à sa main). Rien n'est commandé sans son « oui ».
 */
const commenceParDeterminant = (article: string) =>
  Boolean(article) && DETERMINANT.test(normaliserIntention(article.split(/\s+/)[0]!).split(' ')[0]!);

/**
 * Un commerce de l'annuaire public qui serait en fait sur Tovo ne doit jamais
 * être présenté « hors Tovo ».
 */
// La comparaison tolérante aux fautes coûte cher (466 commerces × toutes les
// enseignes : 10 s, mesuré le 02/10) : elle n'est faite que sur les quelques
// commerces retenus, et son résultat est gardé tant que la liste des
// enseignes ne change pas.
let surTovoEnMemoire: { enseignes: unknown; resultats: Map<string, boolean> } | null = null;

async function estSurTovo(db: SupabaseClient): Promise<(c: Commerce) => boolean> {
  const enseignes = await enseignesApprouvees(db);
  if (surTovoEnMemoire?.enseignes !== enseignes) surTovoEnMemoire = { enseignes, resultats: new Map() };
  const { resultats } = surTovoEnMemoire;
  const variantes = avecVariantes(enseignes);
  return (c) => {
    let sur = resultats.get(c.id);
    if (sur === undefined) {
      // Les mots distinctifs, pas la ressemblance tolérante faite pour les fautes
      // de frappe du client : celle-ci cachait « French Tacos » ou « New York
      // Restaurant », pris pour O'Takoss et AFC (05/10).
      sur = variantes.some((v) => memeCommerce(c.nom, v.name));
      resultats.set(c.id, sur);
    }
    return sur;
  };
}

/**
 * La boutique demandée est dans l'annuaire public (« chez Haddad Khalil ») :
 * Tovo dit où elle est et donne son numéro, livreur d'abord (maquette validée
 * le 01/10, cas 2).
 */
function commerceConnu(commerces: Commerce[], article: string, note?: string): CatalogueAnswer {
  const c = commerces[0]!;
  const achat = article ? `Acheter ${article}` : 'Faire les achats du client';
  const proposition = commenceParDeterminant(article)
    ? `Un livreur peut aller vous y acheter **${article}**`
    : 'Un livreur peut y faire vos achats';
  return {
    content: `**${c.nom}** n’est pas encore sur Tovo, mais le voici. ${proposition} : `
      + 'il vous appelle pour convenir avec vous de ce qu’il faut acheter.',
    summary: {
      boutique_hors_tovo: c.nom,
      article: article || null,
      commerces_hors_tovo: commerces.map((x) => ({
        nom: x.nom, ou: [x.adresse, x.quartier].filter(Boolean).join(', ') || null, telephone_du_commerce: x.telephone,
      })),
      consigne: 'Ce commerce n’est pas sur Tovo : dis où il est. Un livreur peut y aller : il appelle le client '
        + 'pour convenir de l’achat. Ne promets JAMAIS que le livreur avance ou paie l’achat, ni un remboursement. '
        + 'Le numéro affiché est celui DU COMMERCE, '
        + 'jamais celui de Tovo. La carte affiche les boutons : ne pose aucune question.',
    },
    components: [carteCommerces(commerces, achat, HORS_TOVO_OUI, null, note)],
  };
}

/** « 600 m », « 6,3 km ». */
const distanceLisible = (m: number) => (m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(1).replace('.', ',')} km`);
const metresEntre = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) =>
  Math.hypot((a.lat - b.lat) * 111_000, (a.lng - b.lng) * 108_000);

/**
 * Un produit que Tovo n'a pas (« des merguez », « de la pommade ») : les
 * commerces du bon type les plus proches, d'après l'annuaire public
 * (maquette validée le 01/10, cas 1). Rien si l'on ne sait pas quel commerce
 * en vend.
 *
 * C'est l'ASSISTANT qui rédige la réponse (02/10) : il reçoit dans le résumé
 * les commerces, leur type, leur distance et la règle du livreur. La phrase
 * toute faite (« Tovo ne propose pas encore de bien manger des merguez »)
 * recopiait mal les mots du client. `content` n'est plus qu'un secours
 * neutre, qui ne les recopie jamais.
 *
 * @param texte   la demande (et la requête de l'assistant) : sert à choisir le type de commerce
 * @param produit ce que l'assistant a compris (« merguez »), pour la consigne du livreur
 */
export async function alternativesHorsTovo(
  db: SupabaseClient,
  texte: string,
  position?: { lat: number; lng: number } | null,
  produit?: string,
  /** Article 7 : « d'autres », « plus loin » — hors ce qui a déjà été montré, tous types, plus loin. */
  suite?: { dejaVus: ReadonlySet<string>; auDelaDe?: number },
): Promise<CatalogueAnswer | null> {
  const surTovo = await estSurTovo(db);
  const commerces = suite
    ? commercesPourProduit(texte, position, (x) => suite.dejaVus.has(x.nom) || surTovo(x), 3, true, suite.auDelaDe ?? 0)
    : commercesPourProduit(texte, position, surTovo);
  if (commerces.length === 0) return null;
  const quoi = (produit ?? '').trim();
  // La nuit ou le dimanche, un médicament : seules les pharmacies de garde
  // sont ouvertes — ce sont elles qu'on montre.
  if (!suite && commerces.every((c) => c.type === 'pharmacie') && heuresDeGarde()) {
    const garde = await reponseGarde(position, HORS_TOVO_OUI, 3);
    if (garde.components.length > 0) {
      return {
        ...garde,
        content: `À cette heure, seules les pharmacies de garde sont ouvertes. ${garde.content}`,
        summary: { ...garde.summary, consigne: 'Dis en une phrase qu’à cette heure seules les pharmacies de garde sont ouvertes, et que la carte montre les plus proches. Ne donne aucun conseil médical.' },
      };
    }
  }
  const distances = position ? commerces.map((c) => metresEntre(position, c)) : [];
  const proche = distances.length > 0 && Math.min(...distances) < 2000;
  // Un médicament (toutes des pharmacies) : appeler, et l'ordonnance. Pas pour une pommade.
  const pharmacie = commerces.every((c) => c.type === 'pharmacie');
  return {
    // Secours, si l'assistant ne rédige rien : neutre, sans les mots du client.
    content: `Tovo ne le propose pas encore, mais ${commerces.length === 1 ? 'ce commerce en a' : `ces ${libelleDes(commerces)} en ont`} probablement`
      + `${proche ? ', près de vous' : ''} :`
      + (pharmacie ? ' appelez pour vérifier qu’elles l’ont. Pour un médicament sur ordonnance, le livreur aura besoin de votre ordonnance.' : ''),
    summary: {
      produit_hors_tovo: quoi || null,
      commerces_hors_tovo: commerces.map((c, i) => ({
        nom: c.nom,
        type: c.type,
        ou: [c.adresse, c.quartier].filter(Boolean).join(', ') || null,
        distance: position ? distanceLisible(distances[i]!) : null,
        telephone: c.telephone,
      })),
      consigne: 'Tovo n’a pas ce produit. Réponds en une ou deux phrases naturelles, en nommant ce que le client cherche '
        + 'avec tes propres mots (jamais sa phrase recopiée) : ces commerces hors Tovo en ont probablement ; '
        + 'donne le nom du plus proche et sa distance exacte ci-dessus (« près de vous » seulement sous 2 km). '
        + 'Un livreur peut y aller : il appelle le client pour convenir de l’achat. Ne promets JAMAIS que le livreur '
        + 'avance ou paie l’achat, ni un remboursement. '
        + (pharmacie ? 'Pharmacie : invite à appeler pour vérifier qu’elles l’ont, rappelle qu’un médicament sur ordonnance exige l’ordonnance, aucun conseil médical. ' : '')
        + 'La carte affiche les boutons « Envoyer un livreur » et le numéro : ne pose aucune question.',
    },
    components: [avecProduit(carteCommerces(commerces, quoi ? `Acheter : ${quoi}` : 'Faire les achats du client', HORS_TOVO_OUI, position), quoi)],
  };
}

/** La carte retient ce qu'on y cherche : « plus loin ? » repart de là (article 7). */
function avecProduit(carte: Component, produit: string): Component {
  return produit ? { ...carte, data: { ...carte.data, produit } } : carte;
}

/**
 * Tovo n'a rien trouvé : où le trouver ailleurs (02/10). Une seule règle,
 * quelle que soit la phrase du client :
 *  1. un nom que notre annuaire connaît (« Haddad Khalil », « Marina
 *     market ») : où est ce commerce, son numéro, un livreur ;
 *  2. une boutique (le cerveau l'a compris, ou l'assistant l'a nommée) :
 *     Google, s'il la connaît ;
 *  3. un produit : les commerces du bon type les plus proches.
 * La phrase du code n'est qu'une base : le rédacteur la réécrit.
 */
/**
 * ARTICLE 8 de la constitution (05/10) : ce qui existe ailleurs fait partie de
 * la réponse, SOUS ce que Tovo propose. Le client qui tape « merguez » ne sait
 * pas qu'il pourrait demander « d'autres vendeurs » : on le lui montre.
 *  - les spécialistes (leur nom porte le produit) : toujours ;
 *  - si Tovo a peu de résultats (3 au plus) : les commerces du bon type ;
 *  - si Tovo en a beaucoup : rien d'autre (on ne noie pas les partenaires).
 * null si rien d'utile.
 */
export const PEU_DE_RESULTATS = 3;
export async function ailleursEnPlus(
  db: SupabaseClient,
  produit: string,
  position: { lat: number; lng: number } | null | undefined,
  resultatsTovo: number,
): Promise<CatalogueAnswer | null> {
  const quoi = produit.trim();
  if (!quoi) return null;
  const surTovo = await estSurTovo(db);
  const specialistes = specialistesDe(quoi, position, surTovo, 2);
  const duBonType = resultatsTovo <= PEU_DE_RESULTATS
    ? commercesPourProduit(quoi, position, (c) => surTovo(c) || specialistes.some((s) => s.id === c.id), 3)
    : [];
  const commerces = [...specialistes, ...duBonType].slice(0, 3);
  if (commerces.length === 0) return null;
  return {
    content: 'Hors de Tovo, ces commerces en ont probablement ; un livreur peut y aller, il vous appelle pour convenir de l’achat.',
    summary: {
      aussi_hors_tovo: commerces.map((c) => ({
        nom: c.nom, type: c.type, specialiste: specialistes.includes(c),
        distance: position ? `${Math.round(Math.hypot((position.lat - c.lat) * 111_000, (position.lng - c.lng) * 108_000) / 100) / 10} km` : null,
      })),
      consigne: 'Sous les produits Tovo, la carte montre AUSSI des commerces hors Tovo qui en ont probablement (un spécialiste si son nom porte le produit). '
        + 'Dis-le en une courte phrase après avoir présenté ce que Tovo propose. Un livreur peut y aller : il appelle le client pour convenir de l’achat ; jamais d’avance promise.',
    },
    components: [avecProduit(carteCommerces(commerces, `Acheter : ${quoi}`, HORS_TOVO_OUI, position), quoi)],
  };
}

/**
 * UN TYPE DE COMMERCE (« un supermarché pas loin », « tous les supermarchés
 * de Niamey », 05/10). Tovo ne savait chercher qu'un produit ou une boutique
 * nommée : il répondait « je n'ai pas d'autres supermarchés » alors qu'il en a
 * six, et l'annuaire cinquante et un. Désormais (articles 7 et 8) :
 *  - d'abord les boutiques TOVO de ce type, les ouvertes en premier ;
 *  - puis, en dessous, celles de l'annuaire public, les plus proches ;
 *  - « plus loin », « tous », « d'autres » : ce qui n'a pas encore été vu.
 * null si aucun des deux n'en connaît (le chemin habituel reprend).
 */
export async function commercesDuTypeDemande(
  db: SupabaseClient,
  type: TypeCommerceCherche,
  position: { lat: number; lng: number } | null | undefined,
  dejaVus: { boutiques: ReadonlySet<string>; commerces: ReadonlySet<string> },
): Promise<CatalogueAnswer | null> {
  const suite = dejaVus.boutiques.size + dejaVus.commerces.size > 0;
  // Les boutiques Tovo de ce rayon, s'il en a un.
  const rayon = RAYON_DU_COMMERCE[type];
  const categorie = rayon ? await idDuRayon(db, rayon) : undefined;
  let boutiques: Array<Record<string, unknown> & { id: string; is_open: boolean }> = [];
  if (categorie && position) {
    const { data } = await db.rpc('nearby_merchants', {
      origin_lat: position.lat, origin_lng: position.lng, radius_m: 30_000,
      filter_category: categorie, match_count: 50,
    });
    const rangs = ((data ?? []) as Array<Record<string, unknown>>)
      .map((b) => ({ ...b, id: b.id as string, is_open: b.is_open === true }) as Record<string, unknown> & { id: string; is_open: boolean })
      .filter((b) => !dejaVus.boutiques.has(b.id));
    boutiques = (await avecOuvertureReelle(db, rangs))
      // Les ouvertes d'abord, puis les plus proches.
      .sort((a, b) => Number(b.is_open) - Number(a.is_open) || Number(a.distance_m ?? 0) - Number(b.distance_m ?? 0))
      .slice(0, 6);
  }
  // Puis l'annuaire : ni sur Tovo, ni déjà montrés.
  const surTovo = await estSurTovo(db);
  const commerces = commercesDuType(type as TypeCommerce, position,
    (c) => surTovo(c) || dejaVus.commerces.has(c.nom), 5, suite ? 30_000 : 20_000);
  if (boutiques.length === 0 && commerces.length === 0) return null;

  const ouvertes = boutiques.filter((b) => b.is_open).length;
  // Ce qui a été montré, depuis le début de la recherche : « plus loin »,
  // « tous » repartent de là, pas du seul dernier écran (05/10).
  const vus = {
    commerce_type: type,
    deja_vus_boutiques: [...dejaVus.boutiques, ...boutiques.map((b) => b.id)],
    deja_vus_commerces: [...dejaVus.commerces, ...commerces.map((c) => c.nom)],
  };
  return {
    content: [
      boutiques.length ? `Sur Tovo : ${boutiques.length} ${type === 'supermarche' ? 'supermarché(s)' : 'boutique(s)'}, ${ouvertes} ouverte(s) en ce moment.` : '',
      commerces.length ? 'Hors de Tovo, d’autres près de vous ; un livreur peut y aller, il vous appelle pour convenir de l’achat.' : '',
    ].filter(Boolean).join(' '),
    summary: {
      type_de_commerce: type,
      ...(suite ? { suite_de_la_liste: true } : {}),
      boutiques_tovo: boutiques.map((b) => ({ nom: b.name, ouverte: b.is_open, distance_m: b.distance_m })),
      commerces_hors_tovo: commerces.map((c) => ({ nom: c.nom, quartier: c.quartier })),
      consigne: 'Le client cherche des commerces de ce type. Présente d’abord ceux de Tovo (dis combien sont ouverts), puis ceux hors Tovo. '
        + 'Ne dis jamais qu’il n’y en a pas d’autres : la liste montre ce qui est connu.',
    },
    components: avecMemoire([
      ...boutiques.map((m) => merchantCard({
        id: m.id, name: m.name as string, description: (m.description as string | null) ?? null,
        logo_url: (m.logo_url as string | null) ?? null, address_hint: (m.address_hint as string) ?? '',
        is_open: m.is_open, rating: (m.rating as number) ?? 5, prep_time_min: (m.prep_time_min as number) ?? 20,
        distance_m: (m.distance_m as number | null) ?? null,
      } as MerchantRow)),
      ...(commerces.length ? [carteCommerces(commerces, 'Faire les achats du client', HORS_TOVO_OUI, position)] : []),
    ], vus),
  };
}

/**
 * La mémoire de la liste (type cherché, ce qui a été montré) est portée par
 * la dernière carte : celle des commerces hors Tovo, sinon la dernière
 * boutique. Le message suivant la relit (orchestrator.ts).
 */
function avecMemoire(cartes: Component[], memoire: Record<string, unknown>): Component[] {
  const derniere = cartes.at(-1);
  if (!derniere) return cartes;
  return [...cartes.slice(0, -1), { ...derniere, data: { ...derniere.data, ...memoire } }];
}

export async function horsTovo(
  db: SupabaseClient,
  message: string,
  requete: string,
  position: { lat: number; lng: number } | null | undefined,
  options: { boutique?: boolean } = {},
): Promise<CatalogueAnswer | null> {
  const nom = requete.trim();
  if (nom) {
    // Un nom de commerce n'est reconnu que si le client NOMME une boutique
    // (le cerveau a compris « boutique »), ou en donne le nom exact. Sinon
    // c'est un produit : « merguez » trouvait « Nouhou Merguez » comme si le
    // client l'avait demandé, au lieu des plats aux merguez de Tovo (article
    // 1 : le sens, pas les mots). Le vendeur réputé sort quand même, par sa
    // spécialité, parmi les commerces qui en ont (étape 3).
    const nomme = normaliserIntention(nom);
    const connus = commercesNommes(nomme, await estSurTovo(db))
      .filter((c) => options.boutique || normaliserIntention(c.nom) === nomme);
    if (connus.length > 0) {
      noterBoutiqueDemandee(connus[0]!.nom, '', 'annuaire');
      return commerceConnu(connus, '');
    }
    if (options.boutique) {
      const google = await trouverSurGoogle(nom);
      if (google.length > 0) {
        noterBoutiqueDemandee(nom, '', 'google', google[0]!.place_id);
        return commerceConnu(google, '', NOTE_GOOGLE);
      }
      noterBoutiqueDemandee(nom, '', 'inconnue');
    }
  }
  return alternativesHorsTovo(db, `${message} ${nom}`.trim(), position, nom || undefined);
}

async function enseigneHorsTovo(db: SupabaseClient, intent: CatalogueIntent & { missing: string }): Promise<CatalogueAnswer> {
  const nom = enseigneTelleQueDite(intent.query, intent.missing);
  const article = articleAvantEnseigne(intent.query);
  const connus = commercesNommes(intent.missing, await estSurTovo(db));
  if (connus.length > 0) {
    noterBoutiqueDemandee(connus[0]!.nom, article, 'annuaire');
    return commerceConnu(connus, article);
  }
  // Inconnue de notre annuaire : Google, s'il la connaît (« Tchos » tel que
  // le client l'a écrit, fautes comprises — la comparaison les tolère).
  const google = await trouverSurGoogle(nom);
  if (google.length > 0) {
    noterBoutiqueDemandee(nom, article, 'google', google[0]!.place_id);
    return commerceConnu(google, article, NOTE_GOOGLE);
  }
  const avecDeterminant = commenceParDeterminant(article);
  const question = !article
    ? `Voulez-vous qu’un livreur aille y faire vos achats ?`
    : avecDeterminant
      ? `Voulez-vous qu’un livreur aille vous acheter **${article}** là-bas ?`
      : `Voulez-vous qu’un livreur aille vous l’acheter là-bas : **${article}** ?`;
  const achat = article ? `Acheter ${article} chez ${nom}` : `Chez ${nom}`;
  const cherche = sansDeterminant(article);
  noterBoutiqueDemandee(nom, article, 'inconnue');
  return {
    content: `**${nom}** n’est pas encore sur Tovo. ${question} `
      + 'Il vous appelle pour convenir avec vous de ce qu’il faut acheter.',
    summary: {
      boutique_introuvable: intent.missing,
      boutique_hors_tovo: nom,
      article: article || null,
      consigne: 'Les tuiles suffisent : le client répond en touchant l’une d’elles. Ne pose aucune autre question.',
    },
    components: [quickReplies([
      { label: 'Oui, envoyez un livreur', value: `${HORS_TOVO_OUI}${propre(achat)}` },
      cherche
        ? { label: 'Non, voir ce que Tovo propose', value: `${HORS_TOVO_NON}${propre(cherche)}` }
        : { label: 'Non merci', value: HORS_TOVO_NON },
    ])],
  };
}

/**
 * La réponse à une tuile de enseigneHorsTovo.
 *  - oui : la carte « Un livreur va chercher pour vous », déjà remplie de ce
 *    qu'il faut acheter et où ; le client touche « Commander le livreur ».
 *  - non : ce que Tovo propose de ce produit, ou rien s'il n'en a pas nommé.
 */
export async function reponseHorsTovo(db: SupabaseClient, valeur: string): Promise<CatalogueAnswer> {
  if (valeur.startsWith(HORS_TOVO_OUI)) {
    const offre = await offreVille(db);
    // « Acheter … chez X (rue)|+227… » : le numéro du commerce, s'il est
    // connu, devient le contact sur place du livreur.
    const [achat, telephone] = valeur.slice(HORS_TOVO_OUI.length).split(SEP);
    return {
      content: 'Vérifiez ce que le livreur doit acheter, puis touchez **Commander le livreur**.',
      summary: { achat_hors_tovo: achat },
      components: [{
        type: 'courier_form',
        data: {
          mode: 'recuperer',
          // Ce que lit le livreur : quoi acheter, et où. Le client peut le corriger.
          pickup: { hint: achat },
          pickup_contact: telephone || null,
          dropoff: null,
          estimate: offre.prix === null ? null : { price: offre.prix, flat: true },
          callback_minutes: offre.minutes,
          mobile_money: paiementMobileActif,
        },
      }],
    };
  }
  const q = valeur.slice(HORS_TOVO_NON.length).trim();
  if (!q) return { content: 'Très bien. Dites-moi si vous cherchez autre chose.', summary: {}, components: [] };
  const filtre = { q, limit: 8 };
  return searchAnswer(await cataloguePage(db, filtre), filtre);
}

export async function merchantIntentAnswer(db: SupabaseClient, intent: CatalogueIntent): Promise<CatalogueAnswer | null> {
  if (intent.missing) return enseigneHorsTovo(db, intent as CatalogueIntent & { missing: string });
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
