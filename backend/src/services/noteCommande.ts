import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * LA NOTE DE COMMANDE (article 9 de la constitution, 02/10).
 *
 * Ce que le client précise et qu'aucune option ne prévoit (« sans oignons »,
 * « bien cuit », « sonnez deux fois ») est GARDÉ ici, puis part avec sa
 * prochaine commande dans la note que la boutique lit. Il la voit et la
 * modifie au panier. Une seule note par client (table notes_commande,
 * migration 0075, RLS : la sienne seulement).
 *
 * Article 4 : Tovo ne dit « c'est noté » que si l'écriture a RÉUSSI.
 */

const LONGUEUR = 500;

/** La note du client, ou null — jamais d'erreur : une note illisible ne doit pas empêcher d'afficher le panier. */
export async function lireNote(db: SupabaseClient): Promise<string | null> {
  try {
    const { data, error } = await db.from('notes_commande').select('note').maybeSingle();
    if (error) return null;
    return (data?.note as string | undefined) ?? null;
  } catch {
    return null;
  }
}

/**
 * Ajoute une précision à la note (sans doublon). Renvoie la note entière, ou
 * null si elle n'a pas pu être enregistrée (migration absente, réseau) — dans
 * ce cas, on ne prétend pas l'avoir notée.
 */
export async function ajouterALaNote(db: SupabaseClient, userId: string, precision: string): Promise<string | null> {
  const ajout = precision.replace(/\s+/g, ' ').trim();
  if (!ajout) return null;
  const actuelle = await lireNote(db);
  const deja = actuelle?.toLowerCase().includes(ajout.toLowerCase());
  const note = (deja ? actuelle! : [actuelle, ajout].filter(Boolean).join(' ; ')).slice(0, LONGUEUR);
  try {
    const { error } = await db.from('notes_commande')
      .upsert({ user_id: userId, note, maj_le: new Date().toISOString() }, { onConflict: 'user_id' });
    return error ? null : note;
  } catch {
    return null;
  }
}

/** Remplace la note (le client la modifie au panier) ; vide = effacée. */
export async function ecrireNote(db: SupabaseClient, userId: string, note: string): Promise<boolean> {
  const propre = note.replace(/\s+/g, ' ').trim().slice(0, LONGUEUR);
  if (!propre) return effacerNote(db, userId);
  try {
    const { error } = await db.from('notes_commande')
      .upsert({ user_id: userId, note: propre, maj_le: new Date().toISOString() }, { onConflict: 'user_id' });
    return !error;
  } catch {
    return false;
  }
}

export async function effacerNote(db: SupabaseClient, userId: string): Promise<boolean> {
  try {
    const { error } = await db.from('notes_commande').delete().eq('user_id', userId);
    return !error;
  } catch {
    return false;
  }
}
