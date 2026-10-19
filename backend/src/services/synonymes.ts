import { env } from '../config/env.js';
import { serviceClient } from './supabase.js';

/**
 * Le DICTIONNAIRE DES SYNONYMES de la recherche (table `synonymes_recherche`,
 * migration 0084) : « bonbonne » → « bouteille », « tente de cérémonie » →
 * « chapiteau ».
 *
 * Il réécrit la phrase du client, pas les produits : une entrée vaut pour
 * tout le catalogue, celui d'aujourd'hui comme celui de demain. Et il ne sert
 * que lorsque la phrase telle quelle ne trouve RIEN (cataloguePageBrute) :
 * il ne peut donc qu'ajouter des résultats, jamais en retirer ni en
 * reclasser. La règle « tous les mots doivent être présents » reste entière —
 * c'est elle qui empêche les faux résultats.
 *
 * Les entrées viennent des recherches sans résultat des vrais clients (vue
 * `recherches_sans_resultat`), relues par un humain.
 */

export interface Synonyme {
  expression: string;
  remplacement: string;
}

/**
 * La phrase réécrite, ou null si aucun synonyme ne s'applique. `requete` est
 * déjà normalisée (requeteProduitUtilisateur : sans accents, minuscules, mots
 * vides retirés). Une expression ne remplace que des mots entiers ; la plus
 * longue passe d'abord (« tente ceremonie » avant « tente »). Un synonyme
 * REMPLACE, il ne retire jamais : sans « location », « location voiture »
 * cherchait « voiture » et montrait des chargeurs de voiture (19/10).
 */
export function appliquerSynonymes(requete: string, synonymes: readonly Synonyme[]): string | null {
  let texte = ` ${requete} `;
  for (const { expression, remplacement } of [...synonymes].sort((a, b) => b.expression.length - a.expression.length)) {
    if (!expression.trim() || !remplacement.trim()) continue;
    const motif = new RegExp(` ${expression.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} `, 'g');
    texte = texte.replace(motif, ` ${remplacement.trim()} `);
  }
  const mots = [...new Set(texte.split(' ').filter(Boolean))];
  const reecrite = mots.join(' ');
  return reecrite && reecrite !== requete ? reecrite : null;
}

const DUREE_CACHE_MS = 5 * 60_000;
let cache: { quand: number; synonymes: Synonyme[] } | null = null;

/** Les synonymes actifs, gardés 5 minutes. Jamais d'erreur : vide au pire. */
export async function synonymesActifs(): Promise<Synonyme[]> {
  // Les tests unitaires ne parlent pas à la base.
  if (env.NODE_ENV === 'test') return [];
  if (cache && Date.now() - cache.quand < DUREE_CACHE_MS) return cache.synonymes;
  const { data, error } = await serviceClient().from('synonymes_recherche')
    .select('expression, remplacement').eq('actif', true);
  // Table absente (migration pas encore passée) ou panne : on cherche sans.
  if (error) return cache?.synonymes ?? [];
  cache = { quand: Date.now(), synonymes: (data ?? []) as Synonyme[] };
  return cache.synonymes;
}
