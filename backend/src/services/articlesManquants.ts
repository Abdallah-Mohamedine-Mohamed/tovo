/**
 * Un article manque dans une commande (02/11, maquette validée).
 *
 * La boutique coche l'article ; le client choisit : le remplacer (au plus
 * deux propositions de la même boutique, même rayon, prix proche — des
 * règles, pas l'IA), le retirer, ou annuler. Sans réponse en 10 minutes,
 * l'article est retiré et la commande continue. L'article passe « à
 * vérifier » dans le catalogue de la boutique (products.manquant_le) et
 * n'est plus proposé jusqu'à ce qu'elle le remette.
 *
 * Tout passe par la clé serveur : le client n'écrit pas dans la commande
 * d'une boutique, ni la boutique dans le choix du client. Chaque fonction
 * vérifie donc elle-même qui agit.
 */
import { serviceClient } from './supabase.js';
import { jetons, purger } from './orderNotifications.js';
import { sendPush } from './notifications.js';

/** Sans réponse du client, l'article est retiré au bout de ce délai. */
export const DELAI_REPONSE_MIN = 10;
/** Un remplacement proposé doit coûter à ± 25 % de l'article manquant. */
const ECART_PRIX = 0.25;
const MAX_SUGGESTIONS = 2;

export class RefusManquant extends Error {
  constructor(message: string, readonly status = 409) {
    super(message);
  }
}

export interface ProduitCandidat {
  id: string;
  name: string;
  price: number;
  image_url: string | null;
  category_id: string | null;
  is_available: boolean;
}

export interface Suggestion { product_id: string; nom: string; prix: number; image_url: string | null }

/**
 * Les remplacements proposés : même boutique (déjà filtrée), même rayon,
 * en vente, pas déjà dans la commande, prix à ± 25 %. Le prix le plus
 * proche d'abord, puis le plus commandé.
 */
export function choisirSuggestions(
  manquant: { product_id: string | null; prix: number; category_id: string | null },
  candidats: ProduitCandidat[],
  dejaCommandes: Set<string>,
  popularite: Map<string, number> = new Map(),
): Suggestion[] {
  return candidats
    .filter((p) => p.is_available && p.id !== manquant.product_id && !dejaCommandes.has(p.id))
    .filter((p) => manquant.category_id !== null && p.category_id === manquant.category_id)
    .filter((p) => Math.abs(p.price - manquant.prix) <= manquant.prix * ECART_PRIX)
    .sort((a, b) =>
      Math.abs(a.price - manquant.prix) - Math.abs(b.price - manquant.prix)
      || (popularite.get(b.id) ?? 0) - (popularite.get(a.id) ?? 0)
      || a.name.localeCompare(b.name, 'fr'))
    .slice(0, MAX_SUGGESTIONS)
    .map((p) => ({ product_id: p.id, nom: p.name, prix: p.price, image_url: p.image_url }));
}

const francs = (n: number) => `${Math.round(n).toLocaleString('fr-FR').replace(/\s/g, ' ')} F`;

async function pousser(destinataire: string | null | undefined, app: 'client' | 'merchant', titre: string, corps: string, data: Record<string, string>) {
  if (!destinataire) return;
  const tokens = await jetons(destinataire, app);
  if (!tokens.length) return;
  const resultat = await sendPush(tokens.map((token) => ({ token, title: titre, body: corps, data })));
  await purger(resultat.invalidTokens);
}

/**
 * La boutique signale un ou plusieurs articles manquants d'une commande
 * qu'elle n'a pas encore acceptée.
 */
export async function signalerManquants(proprietaireId: string, orderId: string, itemIds: string[]): Promise<number> {
  const db = serviceClient();
  const { data: commande, error } = await db.from('orders')
    .select('id, user_id, status, merchant_id, merchants(owner_id, name), order_items(id, product_id, product_name, unit_price, quantity)')
    .eq('id', orderId).maybeSingle();
  if (error) throw error;
  const relation = commande?.merchants as unknown;
  const boutique = (Array.isArray(relation) ? relation[0] : relation) as { owner_id?: string; name?: string } | null | undefined;
  if (!commande || boutique?.owner_id !== proprietaireId) throw new RefusManquant('Commande introuvable.', 404);
  if (commande.status !== 'pending') throw new RefusManquant('La commande est déjà acceptée : appelez le client.');

  const articles = (commande.order_items ?? []) as Array<{ id: string; product_id: string | null; product_name: string; unit_price: number; quantity: number }>;
  const coches = articles.filter((a) => itemIds.includes(a.id));
  if (!coches.length) throw new RefusManquant('Aucun article de cette commande.', 400);

  const { data: deja } = await db.from('articles_manquants').select('order_item_id').eq('order_id', orderId);
  const dejaSignales = new Set((deja ?? []).map((d) => d.order_item_id as string));
  const nouveaux = coches.filter((a) => !dejaSignales.has(a.id));
  if (!nouveaux.length) return 0;

  // Les remplacements : les produits en vente de la même boutique.
  const ids = nouveaux.map((a) => a.product_id).filter((x): x is string => !!x);
  const { data: manquantsProduits } = ids.length
    ? await db.from('products').select('id, category_id').in('id', ids)
    : { data: [] as Array<{ id: string; category_id: string | null }> };
  const rayonDe = new Map((manquantsProduits ?? []).map((p) => [p.id as string, (p.category_id as string | null) ?? null]));
  const { data: candidats } = await db.from('products')
    .select('id, name, price, image_url, category_id, is_available')
    .eq('merchant_id', commande.merchant_id as string).eq('is_available', true).limit(1000);
  const dejaCommandes = new Set(articles.map((a) => a.product_id).filter((x): x is string => !!x));

  const lignes = nouveaux.map((a) => ({
    order_id: orderId,
    order_item_id: a.id,
    product_id: a.product_id,
    nom: a.product_name,
    quantite: a.quantity,
    prix_unitaire: a.unit_price,
    suggestions: choisirSuggestions(
      { product_id: a.product_id, prix: a.unit_price, category_id: a.product_id ? rayonDe.get(a.product_id) ?? null : null },
      (candidats ?? []) as ProduitCandidat[],
      dejaCommandes,
    ),
  }));
  const { error: erreurInsertion } = await db.from('articles_manquants').insert(lignes);
  if (erreurInsertion) throw erreurInsertion;

  // « À vérifier » : plus proposé aux clients jusqu'à ce que la boutique le remette.
  if (ids.length) {
    await db.from('products').update({ is_available: false, manquant_le: new Date().toISOString() }).in('id', ids);
  }
  await db.from('orders').update({ attente_client: true }).eq('id', orderId);

  const premier = nouveaux[0]!;
  const quoi = nouveaux.length > 1 ? `${nouveaux.length} articles` : premier.product_name;
  await pousser(commande.user_id as string, 'client', 'Un article manque',
    `${boutique?.name ?? 'La boutique'} n’a plus de ${quoi}. Touchez pour choisir.`,
    { order_id: orderId, kind: 'article_manquant' }).catch(() => undefined);
  return nouveaux.length;
}

export type Decision = 'remplacer' | 'retirer' | 'annuler';

/**
 * Le choix pour un article manquant : par le client (vérifié), ou d'office
 * (`auto`, après le délai).
 */
export async function deciderManquant(
  qui: { clientId: string } | { auto: true },
  orderId: string,
  manquantId: string,
  decision: Decision,
  remplacementId?: string,
): Promise<{ statut: string; total: number }> {
  const db = serviceClient();
  const { data: m, error } = await db.from('articles_manquants')
    .select('id, order_id, order_item_id, decision, suggestions, nom, orders(id, user_id, status, merchant_id, merchants(owner_id, name))')
    .eq('id', manquantId).eq('order_id', orderId).maybeSingle();
  if (error) throw error;
  const commande = (Array.isArray(m?.orders) ? m?.orders[0] : m?.orders) as Record<string, any> | null;
  if (!m || !commande) throw new RefusManquant('Introuvable.', 404);
  if ('clientId' in qui && commande.user_id !== qui.clientId) throw new RefusManquant('Introuvable.', 404);
  if (m.decision !== 'attente') throw new RefusManquant('Ce choix est déjà fait.');
  if (commande.status === 'cancelled') throw new RefusManquant('La commande est annulée.');

  const maintenant = new Date().toISOString();
  let decisionFinale: Decision = decision;
  let remplacementRetenu: string | null = null;

  if (decision === 'remplacer') {
    const suggestions = (m.suggestions ?? []) as Suggestion[];
    const choisie = suggestions.find((s) => s.product_id === remplacementId);
    if (!choisie) throw new RefusManquant('Ce remplacement n’est pas proposé.', 400);
    // Le prix du jour, pas celui de la proposition : il a pu changer.
    const { data: produit } = await db.from('products').select('id, name, price, is_available').eq('id', choisie.product_id).maybeSingle();
    if (!produit?.is_available) throw new RefusManquant('Ce remplacement vient de manquer lui aussi. Choisissez autre chose.');
    const { data: ligne } = await db.from('order_items').select('quantity').eq('id', m.order_item_id as string).maybeSingle();
    const quantite = (ligne?.quantity as number | undefined) ?? 1;
    const { error: e } = await db.from('order_items').update({
      product_id: produit.id, product_name: produit.name, unit_price: produit.price,
      line_total: (produit.price as number) * quantite, selections: [], selections_label: '',
    }).eq('id', m.order_item_id as string);
    if (e) throw e;
    remplacementRetenu = produit.id as string;
  } else if (decision === 'retirer') {
    if (m.order_item_id) {
      const { error: e } = await db.from('order_items').delete().eq('id', m.order_item_id as string);
      if (e) throw e;
    }
    // Plus rien à préparer : la commande est annulée, pas livrée vide.
    const { count } = await db.from('order_items').select('id', { count: 'exact', head: true }).eq('order_id', orderId);
    if (!count) decisionFinale = 'annuler';
  }

  await db.from('articles_manquants').update({
    decision: decisionFinale, remplacement_product_id: remplacementRetenu,
    decide_le: maintenant, decide_par: 'auto' in qui ? 'auto' : 'client',
  }).eq('id', manquantId);

  if (decisionFinale === 'annuler') {
    // Les autres manquants de la commande n'ont plus d'objet.
    await db.from('articles_manquants').update({ decision: 'annuler', decide_le: maintenant, decide_par: 'auto' in qui ? 'auto' : 'client' })
      .eq('order_id', orderId).eq('decision', 'attente');
    await db.from('orders').update({ status: 'cancelled', cancelled_reason: 'Article indisponible', attente_client: false }).eq('id', orderId);
  } else {
    await db.rpc('recalculer_commande', { p_order_id: orderId });
    const { count } = await db.from('articles_manquants').select('id', { count: 'exact', head: true })
      .eq('order_id', orderId).eq('decision', 'attente');
    if (!count) await db.from('orders').update({ attente_client: false }).eq('id', orderId);
  }

  const { data: apres } = await db.from('orders').select('status, total').eq('id', orderId).single();
  const boutique = (Array.isArray(commande.merchants) ? commande.merchants[0] : commande.merchants) as { owner_id?: string } | null;
  const message = decisionFinale === 'annuler' ? 'Le client a annulé la commande.'
    : decisionFinale === 'remplacer' ? `Remplacement choisi pour ${m.nom}. Vous pouvez accepter.`
      : 'auto' in qui ? `Sans réponse du client : ${m.nom} est retiré. Vous pouvez accepter.`
        : `Le client a retiré ${m.nom}. Vous pouvez accepter.`;
  await pousser(boutique?.owner_id, 'merchant', decisionFinale === 'annuler' ? 'Commande annulée' : 'Le client a répondu',
    `${message} Nouveau total : ${francs(apres?.total as number ?? 0)}.`,
    { order_id: orderId, kind: 'reponse_manquant' }).catch(() => undefined);

  return { statut: apres?.status as string, total: apres?.total as number };
}

/** Les manquants restés sans réponse : retirés d'office (appelé chaque minute). */
export async function retirerLesManquantsOublies(): Promise<number> {
  const db = serviceClient();
  const seuil = new Date(Date.now() - DELAI_REPONSE_MIN * 60_000).toISOString();
  const { data } = await db.from('articles_manquants').select('id, order_id')
    .eq('decision', 'attente').lt('signale_le', seuil).limit(50);
  let n = 0;
  for (const m of data ?? []) {
    try {
      await deciderManquant({ auto: true }, m.order_id as string, m.id as string, 'retirer');
      n += 1;
    } catch {
      // Déjà décidé entre-temps, ou commande annulée : rien à faire.
    }
  }
  return n;
}
