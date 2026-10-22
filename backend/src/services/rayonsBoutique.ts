/**
 * Les catégories PROPRES à une boutique (migration 0087, Niger Beauté 22/10).
 *
 * Une boutique en affichage « categories » ne montre sur sa page que ses
 * catégories : une icône, un nom. Une catégorie ouvre ses articles, que des
 * pastilles (ses sous-catégories) filtrent sur place. Les autres boutiques
 * gardent leur carte, rayon après rayon.
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import { toutLire } from '../ai/banc/lire.js';
import { commandesRecentes, parPopularite } from './popularite.js';

export type Affichage = 'carte' | 'categories';

export interface RayonBoutique {
  cle: string;
  nom: string;
  icone_url: string | null;
  ordre: number;
  sous_rayons: string[];
}

/** « categories » seulement si la base le dit : toute autre valeur, ou rien, garde la carte. */
export function affichageDe(valeur: unknown): Affichage {
  return valeur === 'categories' ? 'categories' : 'carte';
}

/**
 * Les catégories à afficher, dans leur ordre, avec leur nombre de produits
 * en vente. Une catégorie vide disparaît : une icône qui mène à une page vide
 * fait croire que la boutique n'a rien.
 */
export function rayonsAffiches(
  rayons: RayonBoutique[],
  produits: Array<{ rayon_boutique: string | null }>,
): Array<{ cle: string; nom: string; icone_url: string | null; produits: number }> {
  const parRayon = new Map<string, number>();
  for (const p of produits) {
    if (p.rayon_boutique) parRayon.set(p.rayon_boutique, (parRayon.get(p.rayon_boutique) ?? 0) + 1);
  }
  return [...rayons]
    .sort((a, b) => a.ordre - b.ordre || a.nom.localeCompare(b.nom, 'fr'))
    .filter((r) => (parRayon.get(r.cle) ?? 0) > 0)
    .map((r) => ({ cle: r.cle, nom: r.nom, icone_url: r.icone_url, produits: parRayon.get(r.cle)! }));
}

/**
 * Les pastilles d'une catégorie : l'ordre voulu par la boutique d'abord,
 * puis celles qu'il ne cite pas, de la plus fournie à la moins fournie.
 * Seules celles qui ont des produits. Une seule pastille ne filtre rien :
 * aucune n'est alors renvoyée (l'app n'affiche que les articles).
 */
export function pastilles(ordre: string[], produits: Array<{ sous_rayon: string | null }>): string[] {
  const compte = new Map<string, number>();
  for (const p of produits) {
    if (p.sous_rayon) compte.set(p.sous_rayon, (compte.get(p.sous_rayon) ?? 0) + 1);
  }
  const voulues = ordre.filter((s) => compte.has(s));
  const autres = [...compte.keys()]
    .filter((s) => !voulues.includes(s))
    .sort((a, b) => compte.get(b)! - compte.get(a)! || a.localeCompare(b, 'fr'));
  const toutes = [...voulues, ...autres];
  return toutes.length > 1 ? toutes : [];
}

async function lireRayons(db: SupabaseClient, merchantId: string): Promise<RayonBoutique[]> {
  const { data, error } = await db.from('rayons_boutique')
    .select('cle, nom, icone_url, ordre, sous_rayons')
    .eq('merchant_id', merchantId);
  if (error) throw error;
  return (data ?? []) as RayonBoutique[];
}

/** La page d'une boutique en catégories : ses catégories et le nombre d'articles en vente. */
export async function categoriesDeLaBoutique(db: SupabaseClient, merchantId: string) {
  const [rayons, produits] = await Promise.all([
    lireRayons(db, merchantId),
    // Plus de 1 000 produits possibles : page par page.
    toutLire<{ rayon_boutique: string | null }>((de, a) => db.from('products')
      .select('rayon_boutique')
      .eq('merchant_id', merchantId).eq('is_available', true)
      .order('id').range(de, a)),
  ]);
  if (produits.error) throw produits.error;
  return { rayons: rayonsAffiches(rayons, produits.data), total: produits.data.length };
}

/**
 * Une catégorie de la boutique : ses pastilles et TOUS ses articles en vente,
 * les plus commandés d'abord (aucun chiffre envoyé). null si la catégorie
 * n'existe pas. L'app filtre et trie sur place : pas un appel par pastille.
 */
export async function articlesDuRayon(
  db: SupabaseClient,
  merchant: { id: string; name: string; is_open: boolean },
  cle: string,
) {
  const [rayons, produits, parProduit] = await Promise.all([
    lireRayons(db, merchant.id),
    toutLire<Record<string, unknown> & { id: string }>((de, a) => db.from('products')
      .select('id, name, description, image_url, price, is_available, sous_rayon, product_options(is_required)')
      .eq('merchant_id', merchant.id).eq('is_available', true).eq('rayon_boutique', cle)
      .order('name').order('id').range(de, a)),
    commandesRecentes(),
  ]);
  const rayon = rayons.find((r) => r.cle === cle);
  if (!rayon) return null;
  if (produits.error) throw produits.error;
  const items = parPopularite(produits.data, parProduit).map((p) => ({
    id: p.id, name: p.name, description: p.description, image_url: p.image_url,
    price: p.price, is_available: p.is_available, sous_rayon: p.sous_rayon ?? null,
    merchant_id: merchant.id, merchant_name: merchant.name, merchant_open: merchant.is_open,
    // « À personnaliser » : le « + » ouvre alors la fiche (comme la carte).
    requires_options: ((p.product_options ?? []) as Array<{ is_required: boolean }>).some((o) => o.is_required),
  }));
  return {
    rayon: { cle: rayon.cle, nom: rayon.nom, icone_url: rayon.icone_url },
    pastilles: pastilles(rayon.sous_rayons, items as Array<{ sous_rayon: string | null }>),
    items,
    total: items.length,
  };
}
