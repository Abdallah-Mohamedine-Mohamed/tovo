import type { AuthProvider } from '@refinedev/core';
import { supabaseClient } from './supabaseClient';

/**
 * Authentification de l'admin.
 *
 * Deux contrôles, et le second est le seul qui compte vraiment.
 *
 * Le premier refuse la connexion à qui n'a pas le rôle `admin` dans
 * `profiles`. C'est du confort : sans lui, un boutiquier qui connaîtrait
 * l'URL verrait une interface vide et déroutante.
 *
 * Le second est la RLS. Même si ce fichier était contourné — le code d'une
 * application web est public par nature — la base ne renverrait rien de plus
 * que ce que `is_admin()` autorise. C'est là qu'est la sécurité, pas ici.
 */
export const authProvider: AuthProvider = {
  login: async ({ email, password }) => {
    const { data, error } = await supabaseClient.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      return { success: false, error: { name: 'Connexion refusée', message: error.message } };
    }
    if (!data.user) {
      return {
        success: false,
        error: { name: 'Connexion refusée', message: 'Identifiants invalides.' },
      };
    }

    const { data: profil } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', data.user.id)
      .single();

    if (profil?.role !== 'admin') {
      // Déconnexion immédiate : laisser une session ouverte à un non-admin
      // n'apporterait rien et brouillerait les journaux.
      await supabaseClient.auth.signOut();
      return {
        success: false,
        error: {
          name: 'Accès refusé',
          message: 'Ce compte n’a pas les droits d’administration.',
        },
      };
    }

    return { success: true, redirectTo: '/orders' };
  },

  logout: async () => {
    await supabaseClient.auth.signOut();
    return { success: true, redirectTo: '/login' };
  },

  check: async () => {
    const { data } = await supabaseClient.auth.getSession();
    return data.session
      ? { authenticated: true }
      : { authenticated: false, redirectTo: '/login' };
  },

  getPermissions: async () => {
    const { data } = await supabaseClient.auth.getUser();
    if (!data.user) return null;

    const { data: profil } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', data.user.id)
      .single();

    return profil?.role ?? null;
  },

  getIdentity: async () => {
    const { data } = await supabaseClient.auth.getUser();
    if (!data.user) return null;
    return { id: data.user.id, name: data.user.email ?? 'Administrateur' };
  },

  onError: async (error) => {
    // 401/403 renvoyés par PostgREST : la session a expiré ou les droits ont
    // changé. On renvoie vers la connexion plutôt que d'afficher une page
    // vide inexplicable.
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return { logout: true, redirectTo: '/login', error };
    }
    return { error };
  },
};
