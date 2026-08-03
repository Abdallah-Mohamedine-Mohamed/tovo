import { createClient } from '@refinedev/supabase';

/**
 * Client Supabase de l'admin.
 *
 * La clé utilisée est la clé **publishable**, jamais la secrète. Tout ce qui
 * est préfixé `VITE_` finit dans le bundle JavaScript, donc lisible par
 * quiconque ouvre les outils de développement. La sécurité de cette
 * interface repose entièrement sur la RLS et sur `is_admin()`, pas sur le
 * secret d'une clé.
 *
 * Conséquence directe : un utilisateur non-admin qui parviendrait à ouvrir
 * l'interface ne verrait rien de plus que ce que la base lui accorde.
 */
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!url || !key) {
  throw new Error(
    'Configuration manquante : renseignez VITE_SUPABASE_URL et VITE_SUPABASE_ANON_KEY dans admin/.env.local',
  );
}

export const supabaseClient = createClient(url, key, {
  db: { schema: 'public' },
  auth: { persistSession: true },
});
