import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { env } from '../config/env.js';

/**
 * Deux clients, deux usages, et la distinction n'est pas négociable.
 *
 *  - userClient(jwt)  : toute opération déclenchée par un utilisateur, y
 *    compris l'exécution des outils de l'IA. La RLS s'applique, donc reste la
 *    dernière ligne de défense même si le modèle est manipulé par du texte
 *    injecté dans un nom de produit.
 *
 *  - serviceClient()  : uniquement les traitements sans utilisateur — dispatch
 *    BullMQ, génération d'embeddings, ETL de migration, hook d'auth. Ce client
 *    ignore la RLS.
 *
 * Règle de revue : un appel à serviceClient() dans src/ai/ est un bug.
 */

let cachedServiceClient: SupabaseClient | null = null;

export function serviceClient(): SupabaseClient {
  cachedServiceClient ??= createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cachedServiceClient;
}

/**
 * Client agissant au nom de l'utilisateur porteur du JWT.
 * Un client par requête : ne jamais mettre en cache, le JWT change.
 */
export function userClient(accessToken: string): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

/** Client anonyme, pour le catalogue public uniquement. */
export function anonClient(): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
