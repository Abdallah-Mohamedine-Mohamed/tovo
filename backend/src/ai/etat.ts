import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * L'ÉTAT DU PARCOURS (article 2 de la constitution, 02/10).
 *
 * Ce que le client a sous les yeux et ce qui attend sa réponse, dit en
 * clair au cerveau : un choix d'agence en attente, une carte de course
 * ouverte mais pas commandée, une liste de produits, la carte d'options d'un
 * produit… et s'il a une commande en cours. Un message court se lit avec
 * cela : « centre aéré » complète le choix d'agence, « laisse tomber » ferme
 * la carte de course (rien à annuler), « sans oignons » précise le produit en
 * cours de choix — sans qu'aucune de ces phrases ait sa règle à elle.
 *
 * Ne lève jamais : sans état, le cerveau lit le message seul, comme avant.
 */

type Composant = { type?: unknown; data?: unknown };
type Brut = Record<string, unknown>;

const noms = (items: unknown, n = 5): string[] => (Array.isArray(items) ? items : [])
  .slice(0, n)
  .map((i) => String((i as Brut)?.name ?? (i as Brut)?.nom ?? (i as Brut)?.label ?? '').trim())
  .filter(Boolean);

/** Une ligne par carte affichée : ce qu'elle montre, et si elle attend quelque chose. */
export function decrireEcran(composants: unknown): string[] {
  if (!Array.isArray(composants)) return [];
  const lignes: string[] = [];
  const agences = (composants as Composant[]).filter((c) => c.type === 'merchant_card' && (c.data as Brut)?.choose_branch === true);
  if (agences.length > 1) {
    lignes.push(`Tovo attend que le client CHOISISSE une adresse entre : ${agences.map((c) => String((c.data as Brut).name ?? '')).join(' ; ')}.`);
  }
  for (const c of composants as Composant[]) {
    const d = (c.data ?? {}) as Brut;
    switch (c.type) {
      case 'product_carousel':
      case 'product_list': {
        const total = typeof (d.browse as Brut | undefined)?.total === 'number' ? (d.browse as Brut).total as number : null;
        const requete = String((d.browse as Brut | undefined)?.query ?? '').trim();
        lignes.push(`Une liste de produits${requete ? ` pour « ${requete} »` : ''} : ${noms(d.items).join(' ; ')}${total ? ` (${total} en tout)` : ''}.`);
        break;
      }
      case 'option_selector':
      case 'product_card':
        lignes.push(`Le client est en train de choisir le produit « ${String(d.name ?? '')} » (carte de choix ouverte, pas encore dans le panier).`);
        break;
      case 'courier_form':
        lignes.push('Une carte de course est ouverte : elle n’est PAS commandée, rien n’est en route.');
        break;
      case 'commerces_hors_tovo':
        lignes.push(`Des commerces hors de Tovo : ${noms(d.items).join(' ; ')}.`);
        break;
      case 'quick_replies':
        lignes.push(`Des choix proposés : ${noms(d.items).join(' ; ')}.`);
        break;
      case 'cart_summary':
        lignes.push('Le panier du client est affiché.');
        break;
      case 'order_tracking':
        lignes.push('Le suivi d’une commande est affiché.');
        break;
      case 'merchant_card':
        if (d.choose_branch !== true) lignes.push(`La boutique « ${String(d.name ?? '')} ».`);
        break;
      default:
        break;
    }
  }
  return [...new Set(lignes)].slice(0, 6);
}

/**
 * L'état, en quelques lignes : le dernier écran de Tovo dans cette
 * conversation, et la commande en cours du client (RLS : seulement les
 * siennes).
 */
export async function etatDuParcours(db: SupabaseClient, conversationId: string | undefined): Promise<string | null> {
  try {
    const [dernier, commande] = await Promise.all([
      conversationId
        ? db.from('messages').select('components').eq('conversation_id', conversationId).eq('role', 'assistant')
          .order('created_at', { ascending: false }).limit(1)
        : Promise.resolve({ data: null }),
      db.from('orders').select('status, type').not('status', 'in', '(delivered,cancelled)')
        .gte('placed_at', new Date(Date.now() - 48 * 3_600_000).toISOString())
        .order('placed_at', { ascending: false }).limit(1),
    ]);
    const ecran = decrireEcran((dernier.data as Array<{ components?: unknown }> | null)?.[0]?.components);
    const enCours = (commande.data as Array<{ status: string; type: string }> | null)?.[0];
    return [
      ...(ecran.length ? ['À l’écran :', ...ecran] : ['Rien n’est à l’écran.']),
      enCours
        ? `Commande en cours : oui (${enCours.type === 'courier' ? 'une course' : 'une commande de boutique'}, statut ${enCours.status}).`
        : 'Commande en cours : aucune.',
    ].join(' ');
  } catch {
    return null;
  }
}

/** Le client a-t-il une commande en cours (48 h, ni livrée ni annulée) ? */
export async function commandeEnCours(db: SupabaseClient): Promise<boolean> {
  try {
    const { data } = await db.from('orders').select('id').not('status', 'in', '(delivered,cancelled)')
      .gte('placed_at', new Date(Date.now() - 48 * 3_600_000).toISOString()).limit(1);
    return (data?.length ?? 0) > 0;
  } catch {
    return true; // dans le doute, on ne cache pas une commande au client
  }
}
