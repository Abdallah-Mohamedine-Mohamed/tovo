import type { PostgrestError } from '@supabase/supabase-js';

/**
 * Traduction des erreurs Postgres en réponses HTTP.
 *
 * Les fonctions de la base lèvent des codes explicites (voir migration 0005) :
 *   P0001 — règle métier violée      → 400
 *   P0002 — ressource absente        → 404
 *   P0003 — conflit d'état           → 409
 *   23505 — violation d'unicité      → 409
 *   42501 — refusé par la RLS        → 403
 *
 * Le message de la base est renvoyé tel quel pour ces codes : il est écrit
 * pour être lu par l'utilisateur (« panier déjà ouvert chez une autre
 * boutique »). Pour tout le reste, on renvoie un message générique — une
 * erreur Postgres brute expose la structure de la base.
 */

const MESSAGES_TRANSMISSIBLES = new Set(['P0001', 'P0002', 'P0003']);

export interface HttpFailure {
  status: number;
  body: { error: string; code?: string };
}

export function toHttpFailure(error: PostgrestError): HttpFailure {
  const code = error.code ?? '';

  const status =
    code === 'P0002'
      ? 404
      : code === 'P0003' || code === '23505'
        ? 409
        : code === 'P0001'
          ? 400
          : code === '42501'
            ? 403
            : 500;

  // Les messages de nos `raise exception` sont écrits pour être lus par
  // l'utilisateur. On les transmet tels quels : ils contiennent souvent une
  // précision utile après un deux-points (« option obligatoire non
  // renseignée : Portion »), qu'il ne faut surtout pas amputer.
  const message = MESSAGES_TRANSMISSIBLES.has(code)
    ? error.message.trim() || 'requête invalide'
    : status === 403
      ? 'accès refusé'
      : status === 500
        ? 'erreur interne'
        : 'requête invalide';

  return { status, body: code ? { error: message, code } : { error: message } };
}
