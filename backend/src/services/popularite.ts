import { env } from '../config/env.js';
import { serviceClient } from './supabase.js';

/**
 * Ce que les autres commandent : de quoi CLASSER, jamais un chiffre affiché.
 *
 * Le client ne veut aucun nombre de commandes à l'écran (26/09). Le compte
 * sert seulement à faire remonter les produits les plus commandés (en tête
 * de la page d'une enseigne, et d'abord dans chaque rayon), et à marquer LE
 * plus commandé d'une liste (`plus_commande: true`) — sans le chiffre, qui ne
 * quitte pas le serveur.
 *
 * Commandes des 30 derniers jours, hors annulées ; un produit compte une
 * fois par commande qui le contient. Lu avec la clé serveur (les commandes
 * des autres ne sont pas lisibles par RLS), gardé 5 minutes en mémoire.
 */

/** En dessous, un produit n'est pas « le plus commandé » : une commande isolée ne dit rien. */
export const SEUIL_POPULARITE = 2;
const FENETRE_JOURS = 30;
const DUREE_CACHE_MS = 5 * 60_000;

let cache: { quand: number; parProduit: Map<string, number> } | null = null;
let enCours: Promise<Map<string, number>> | null = null;

async function lire(): Promise<Map<string, number>> {
  const depuis = new Date(Date.now() - FENETRE_JOURS * 86_400_000).toISOString();
  const { data, error } = await serviceClient()
    .from('order_items')
    .select('product_id, order_id, orders!inner(placed_at, status)')
    .gte('orders.placed_at', depuis)
    .neq('orders.status', 'cancelled')
    .limit(20_000);
  if (error) throw error;
  const commandes = new Map<string, Set<string>>();
  for (const ligne of (data ?? []) as Array<{ product_id: string | null; order_id: string }>) {
    if (!ligne.product_id) continue;
    const s = commandes.get(ligne.product_id) ?? new Set<string>();
    s.add(ligne.order_id);
    commandes.set(ligne.product_id, s);
  }
  return new Map([...commandes].map(([id, s]) => [id, s.size]));
}

/** Nombre de commandes récentes par produit. Jamais d'erreur : vide au pire. */
export async function commandesRecentes(): Promise<Map<string, number>> {
  // Les tests unitaires ne parlent pas à la base.
  if (env.NODE_ENV === 'test') return new Map();
  if (cache && Date.now() - cache.quand < DUREE_CACHE_MS) return cache.parProduit;
  enCours ??= lire()
    .then((parProduit) => {
      cache = { quand: Date.now(), parProduit };
      return parProduit;
    })
    .catch(() => cache?.parProduit ?? new Map<string, number>())
    .finally(() => { enCours = null; });
  // Une page n'attend jamais la popularité plus de 800 ms : au pire, les
  // produits restent dans leur ordre habituel.
  let minuterie: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    enCours,
    new Promise<Map<string, number>>((ok) => {
      minuterie = setTimeout(() => ok(cache?.parProduit ?? new Map()), 800);
    }),
  ]).finally(() => clearTimeout(minuterie));
}

/**
 * Les plus commandés d'abord, les autres dans leur ordre d'origine (le tri
 * est stable). Rien n'est ajouté aux produits.
 */
export function parPopularite<T extends { id: string }>(items: T[], parProduit: Map<string, number>): T[] {
  if (parProduit.size === 0) return items;
  return [...items].sort((a, b) => (parProduit.get(b.id) ?? 0) - (parProduit.get(a.id) ?? 0));
}

/**
 * Marque LE plus commandé de la liste (`plus_commande: true`), s'il atteint
 * le seuil. Aucun chiffre n'est ajouté.
 */
export function marquerLePlusCommande<T extends { id: string }>(
  items: T[],
  parProduit: Map<string, number>,
): Array<T & { plus_commande?: true }> {
  let meilleur: string | null = null;
  let max = SEUIL_POPULARITE - 1;
  for (const item of items) {
    const n = parProduit.get(item.id) ?? 0;
    if (n > max) {
      max = n;
      meilleur = item.id;
    }
  }
  return items.map((item) => (item.id === meilleur ? { ...item, plus_commande: true as const } : item));
}

/** Pour les tests. */
export function oublierPopularite(): void {
  cache = null;
}

let cacheBoutiques: { quand: number; parBoutique: Map<string, number> } | null = null;
let boutiquesEnCours: Promise<Map<string, number>> | null = null;

/**
 * Nombre de commandes récentes (30 jours, hors annulées) par boutique. Sert
 * au poids de la rotation des enseignes (services/rotation.ts) ; jamais
 * envoyé à l'app. Vide au pire, jamais d'erreur, 800 ms au plus.
 */
export async function commandesParBoutique(): Promise<Map<string, number>> {
  if (env.NODE_ENV === 'test') return new Map();
  if (cacheBoutiques && Date.now() - cacheBoutiques.quand < DUREE_CACHE_MS) return cacheBoutiques.parBoutique;
  boutiquesEnCours ??= (async () => {
    const depuis = new Date(Date.now() - FENETRE_JOURS * 86_400_000).toISOString();
    const { data, error } = await serviceClient()
      .from('orders')
      .select('merchant_id')
      .gte('placed_at', depuis)
      .neq('status', 'cancelled')
      .not('merchant_id', 'is', null)
      .limit(20_000);
    if (error) throw error;
    const parBoutique = new Map<string, number>();
    for (const { merchant_id: id } of (data ?? []) as Array<{ merchant_id: string }>) {
      parBoutique.set(id, (parBoutique.get(id) ?? 0) + 1);
    }
    return parBoutique;
  })()
    .then((parBoutique) => {
      cacheBoutiques = { quand: Date.now(), parBoutique };
      return parBoutique;
    })
    .catch(() => cacheBoutiques?.parBoutique ?? new Map<string, number>())
    .finally(() => { boutiquesEnCours = null; });
  let minuterie: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    boutiquesEnCours,
    new Promise<Map<string, number>>((ok) => {
      minuterie = setTimeout(() => ok(cacheBoutiques?.parBoutique ?? new Map()), 800);
    }),
  ]).finally(() => clearTimeout(minuterie));
}
