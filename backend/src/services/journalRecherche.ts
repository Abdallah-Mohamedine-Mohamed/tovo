import { env } from '../config/env.js';
import { requeteProduitUtilisateur } from '../ai/intents.js';
import { serviceClient, userClient } from './supabase.js';
import type { CataloguePage } from './catalogue.js';

/** Ce qu'on retient d'une page : l'assistant n'en montre qu'une partie. */
type PageVue = Pick<CataloguePage, 'total'> & Partial<Pick<CataloguePage, 'match_type' | 'synonyme'>> & { items: Array<{ id: unknown }> };

/**
 * Le JOURNAL DES RECHERCHES (table `recherches`, migration 0084) : ce que les
 * clients tapent vraiment, ce qu'on leur a montré, et s'ils ont mis l'un de
 * ces produits au panier.
 *
 * Sans lui, on améliorait la recherche à partir de NOS suppositions (les
 * bancs de scripts/recherche/). Les vues `recherches_sans_resultat` et
 * `recherches_sans_suite` donnent chaque semaine la liste de travail réelle :
 * une entrée au dictionnaire des synonymes, une fiche à corriger, un produit
 * qui manque au catalogue.
 *
 * Rien ici ne ralentit ni ne fait échouer une recherche : tout part après la
 * réponse, et une erreur d'écriture est ignorée.
 */

export type SourceRecherche = 'barre' | 'recherche' | 'assistant';

/**
 * Qui cherche. La barre de recherche est publique (pas de requireAuth), mais
 * l'application envoie le jeton du client connecté : on le vérifie une fois
 * auprès de Supabase, puis on garde la réponse en mémoire.
 */
const proprietaires = new Map<string, string | null>();
async function proprietaire(jeton: string | null | undefined): Promise<string | null> {
  if (!jeton) return null;
  if (proprietaires.has(jeton)) return proprietaires.get(jeton) ?? null;
  const { data } = await userClient(jeton).auth.getUser();
  const id = data.user?.id ?? null;
  // Un jeton vit une heure : la mémoire est vidée bien avant d'enfler.
  if (proprietaires.size > 5_000) proprietaires.clear();
  proprietaires.set(jeton, id);
  return id;
}

/** Le jeton porté par la requête HTTP, s'il y en a un. */
export function jetonDe(entete: string | string[] | undefined): string | null {
  const valeur = Array.isArray(entete) ? entete[0] : entete;
  return valeur?.startsWith('Bearer ') ? valeur.slice(7).trim() || null : null;
}

/**
 * Pendant la frappe, l'application cherche à chaque pause (« pou »,
 * « poulet », « poulet frit ») : seule la dernière dit ce que voulait le
 * client. Une recherche qui en prolonge une autre du même client, à moins
 * de 20 secondes, la remplace.
 */
const FRAPPE_MS = 20_000;

async function ecrire(entree: {
  source: SourceRecherche; phrase: string; user_id: string | null; page: PageVue;
}): Promise<void> {
  const db = serviceClient();
  const phrase = entree.phrase.trim().slice(0, 200);
  if (entree.user_id) {
    const { data: precedente } = await db.from('recherches').select('id, phrase')
      .eq('user_id', entree.user_id).eq('source', entree.source)
      .gte('cree_le', new Date(Date.now() - FRAPPE_MS).toISOString())
      .order('cree_le', { ascending: false }).limit(1).maybeSingle();
    const avant = String(precedente?.phrase ?? '').toLowerCase();
    if (precedente && avant && phrase.toLowerCase().startsWith(avant)) {
      await db.from('recherches').delete().eq('id', precedente.id);
    }
  }
  await db.from('recherches').insert({
    source: entree.source,
    phrase,
    requete: requeteProduitUtilisateur(phrase),
    synonyme: entree.page.synonyme ?? null,
    type_resultat: entree.page.match_type ?? null,
    total: entree.page.total,
    produits: entree.page.items.slice(0, 24).map((item) => String(item.id)),
    user_id: entree.user_id,
  });
}

/**
 * Note une recherche tapée par un client. N'attend rien, ne lève rien.
 * `jeton` (barre publique) ou `userId` (route authentifiée) dit qui cherche.
 */
export function noterRecherche(entree: {
  source: SourceRecherche; phrase: string; page: PageVue;
  userId?: string | null | undefined; jeton?: string | null | undefined;
}): void {
  if (env.NODE_ENV === 'test' || !entree.phrase.trim()) return;
  void (async () => {
    const user_id = entree.userId ?? await proprietaire(entree.jeton).catch(() => null);
    await ecrire({ source: entree.source, phrase: entree.phrase, user_id, page: entree.page });
  })().catch(() => undefined);
}

/**
 * Un produit mis au panier : s'il avait été montré par une recherche du même
 * client dans la demi-heure, cette recherche a abouti.
 */
export function noterAjoutPanier(userId: string, productId: string): void {
  if (env.NODE_ENV === 'test') return;
  void (async () => {
    const db = serviceClient();
    const { data } = await db.from('recherches').select('id')
      .eq('user_id', userId).is('ajoute_panier', null).contains('produits', [productId])
      .gte('cree_le', new Date(Date.now() - 30 * 60_000).toISOString())
      .order('cree_le', { ascending: false }).limit(1).maybeSingle();
    if (data) await db.from('recherches').update({ ajoute_panier: productId }).eq('id', data.id);
  })().catch(() => undefined);
}
