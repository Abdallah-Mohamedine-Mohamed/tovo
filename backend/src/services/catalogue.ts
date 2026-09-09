import type { SupabaseClient } from '@supabase/supabase-js';
import { boutiquesCorrespondantes, normaliserIntention, nomBoutiqueApresMarqueur } from '../ai/intents.js';
import { categoryGrid, merchantCard, productCarousel, type Component, type MerchantRow, type ProductRow } from '../components/builders.js';
import { embed, embeddingsEnabled } from './embeddings.js';

export interface CataloguePage {
  items: ProductRow[];
  total: number;
  offset: number;
  next_offset: number | null;
  match_type: 'exact' | 'similar';
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
  missing?: string;
}

export interface PendingMerchantChoice {
  merchant_ids: string[];
  query: string;
}

const MENU_WORDS = new Set('je j veux voudrais souhaite aimerais peux pourrais voir consulter regarder manger commander prendre acheter montre montrez donne donnez moi la le les de du des d chez a au en carte menu menus produit produits article articles plat plats propose proposes proposer proposez boutique restaurant resto enseigne tous toutes tout toute un une svp merci ce que'.split(' '));

export function requeteSansEnseigne(message: string, merchants: Array<{ id: string; name: string }>): string {
  const words = normaliserIntention(message).split(' ');
  const markerIndex = words.findIndex((word) => ['chez', 'boutique', 'enseigne', 'restaurant', 'resto'].includes(word));
  const aliases = merchants.flatMap((merchant) => [merchant.name, merchant.name.replace(/\([^)]*\)/g, '').trim()]);
  let best: { start: number; length: number } | undefined;
  for (let start = 0; start < words.length; start++) {
    if (markerIndex >= 0 && start <= markerIndex) continue;
    for (let length = words.length - start; length > 0; length--) {
      const phrase = words.slice(start, start + length).join(' ');
      const compact = phrase.replace(/ /g, '');
      if (compact.length < 4) continue;
      const exact = aliases.some((alias) => normaliserIntention(alias).replace(/ /g, '') === compact);
      const fuzzy = aliases.some((alias) => {
        const normalized = normaliserIntention(alias).replace(/ /g, '');
        return Math.abs(compact.length - normalized.length) <= 2
          && boutiquesCorrespondantes(phrase, [{ id: 'candidate', name: alias }]).length > 0;
      });
      if ((exact || fuzzy) && (!best || length > best.length)) best = { start, length };
    }
  }
  if (!best) return message;
  return words.filter((word, index) => (index < best.start || index >= best.start + best.length)
    && !MENU_WORDS.has(word)).join(' ');
}

export async function cataloguePage(db: SupabaseClient, filter: CatalogueFilter, semantic = true): Promise<CataloguePage> {
  const parameters = {
    p_query: filter.q ?? '', p_embedding: null as string | null,
    p_merchants: filter.merchant_ids ?? null, p_category: filter.category_id ?? null,
    p_offset: filter.offset ?? 0, p_limit: filter.limit ?? 24,
  };
  let response = await db.rpc('catalog_products_page', parameters);
  if (response.error) throw response.error;
  let page = response.data as CataloguePage;
  if (page.total === 0 && parameters.p_query && semantic && embeddingsEnabled) {
    const vector = await embed(parameters.p_query, 'query').catch(() => null);
    if (vector) {
      response = await db.rpc('catalog_products_page', { ...parameters, p_embedding: JSON.stringify(vector) });
      if (response.error) throw response.error;
      page = response.data as CataloguePage;
    }
  }
  return page;
}

export async function resolveCatalogueIntent(db: SupabaseClient, message: string, pending?: PendingMerchantChoice): Promise<CatalogueIntent> {
  const catalogue: MerchantRow[] = [];
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await db.from('merchants')
      .select('id, name, description, logo_url, address_hint, is_open, rating, prep_time_min')
      .eq('is_approved', true).order('id').range(offset, offset + 499);
    if (error) throw error;
    catalogue.push(...(data ?? []) as MerchantRow[]);
    if ((data?.length ?? 0) < 500) break;
  }
  const marker = nomBoutiqueApresMarqueur(message);
  const productQuery = normaliserIntention(message).split(' ').filter((word) => !MENU_WORDS.has(word)).join(' ');
  let candidates = boutiquesCorrespondantes(marker ?? message, catalogue);
  if (!marker && candidates.length === 0 && productQuery) {
    candidates = boutiquesCorrespondantes(productQuery, catalogue);
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
    if (exactProducts && exactProducts.total > 0) return { merchants: [], query: message, menu: false };
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
  if (intent.merchants.length > 1) return {
    content: 'Quelle adresse choisissez-vous ? Voici les établissements de cette enseigne.',
    summary: { choix_enseigne_requis: true, boutiques: intent.merchants.map(({ id, name }) => ({ id, nom: name })) },
    components: intent.merchants.map((merchant) => {
      const card = merchantCard(merchant);
      return { ...card, data: { ...card.data, pending_query: intent.query, choose_branch: true } };
    }),
  };
  if (intent.menu && intent.merchants[0]) return merchantMenu(db, intent.merchants[0].id);
  return null;
}

export function searchAnswer(page: CataloguePage, filter: CatalogueFilter): CatalogueAnswer {
  const query = filter.q ?? '';
  const similar = page.match_type === 'similar';
  const preview = page.items.slice(0, 8);
  return {
    content: page.total === 0 ? `Aucun résultat pour **${query}**.`
      : similar ? 'Voici des suggestions proches de votre demande. Vous pouvez parcourir les résultats.'
      : `**${page.total} produits** correspondent à votre recherche. Vous pouvez parcourir les résultats et choisir votre enseigne.`,
    summary: { total: page.total, affiches: preview.length, suggestions: similar,
      produits: preview.map((product) => ({ id: product.id, nom: product.name, prix: product.price, boutique: product.merchant_name, a_personnaliser: product.requires_options ?? false })),
      consigne: 'Le carrousel est un aperçu. Le total concerne tous les résultats accessibles dans le catalogue.' },
    components: preview.length ? [productCarousel(preview, query, {
      query, total: page.total, merchant_ids: filter.merchant_ids, category_id: filter.category_id,
    })] : [],
  };
}
