import { supabaseClient } from './supabaseClient';

/**
 * Appels au backend Tovo, pour ce que la base seule ne sait pas faire.
 *
 * L'admin passe d'habitude par PostgREST via Refine, ce qui suffit tant
 * qu'écrire une ligne revient à écrire une ligne. Les offres externes font
 * exception : `compare_prices` exige un embedding, et une offre enregistrée
 * sans vecteur n'apparaîtrait dans aucune comparaison — visible ici,
 * invisible pour les clients, sans le moindre message d'erreur.
 *
 * Le calcul de cet embedding demande la clé Gemini, qui n'a rien à faire
 * dans un bundle web. Ces écritures passent donc par le backend.
 */

const base = import.meta.env.VITE_API_BASE_URL as string | undefined;

export class BackendIndisponible extends Error {
  constructor() {
    super(
      'VITE_API_BASE_URL n’est pas renseignée : impossible de joindre le backend Tovo. ' +
        'Ajoutez-la dans admin/.env.local.',
    );
    this.name = 'BackendIndisponible';
  }
}

/**
 * Requête authentifiée vers le backend.
 *
 * Le jeton est celui de la session Supabase en cours : le backend le vérifie
 * et relit le rôle en base. L'interface ne décide de rien — un utilisateur
 * qui forcerait l'affichage de cette page se ferait refuser côté serveur.
 */
export async function appelerBackend<T>(
  methode: 'GET' | 'POST' | 'PATCH' | 'DELETE',
  chemin: string,
  corps?: unknown,
): Promise<T> {
  if (!base) throw new BackendIndisponible();

  const { data } = await supabaseClient.auth.getSession();
  const jeton = data.session?.access_token;
  if (!jeton) throw new Error('Session expirée, reconnectez-vous.');

  const reponse = await fetch(`${base.replace(/\/$/, '')}${chemin}`, {
    method: methode,
    headers: {
      Authorization: `Bearer ${jeton}`,
      ...(corps ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(corps ? { body: JSON.stringify(corps) } : {}),
  });

  const texte = await reponse.text();
  let charge: unknown = null;
  try {
    charge = texte ? JSON.parse(texte) : null;
  } catch {
    charge = null;
  }

  if (!reponse.ok) {
    const details = charge as { message?: string; error?: string } | null;
    // Le message du backend d'abord : il explique le refus en français,
    // là où un code HTTP seul laisse l'admin sans piste.
    throw new Error(details?.message ?? details?.error ?? `Le backend a répondu ${reponse.status}`);
  }

  return charge as T;
}
