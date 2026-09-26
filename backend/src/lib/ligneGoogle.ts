import { Agent } from 'undici';

/**
 * Une ligne gardée ouverte vers Google (Gemini).
 *
 * Node ferme une connexion inactive au bout de 4 s. Or les messages d'un
 * client sont espacés : presque chaque appel rouvrait une connexion chiffrée.
 * Mesuré le 26/09 (scripts/banc-ia/connexion.ts) : 0,9 s après 1 s de
 * silence, 1,2 à 1,8 s après 8 s — jusqu'à 0,9 s perdue par message.
 *
 * Ici : les connexions restent ouvertes une minute, et `entretenir` les
 * touche régulièrement (lecture gratuite de la fiche du modèle, aucun jeton).
 */
export const ligneGoogle = new Agent({
  keepAliveTimeout: 60_000,
  keepAliveMaxTimeout: 10 * 60_000,
  connections: 16,
});

/** À passer à `fetch` pour tout appel vers generativelanguage.googleapis.com. */
export const viaLigneGoogle = { dispatcher: ligneGoogle } as unknown as RequestInit;

/**
 * Touche la ligne toutes les `intervalleMs` pour qu'elle reste chaude.
 * Retourne de quoi arrêter (tests, arrêt du serveur).
 */
export function entretenirLigneGoogle(cle: string | undefined, modele: string, intervalleMs = 20_000): () => void {
  if (!cle) return () => {};
  const toucher = () => {
    void fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}`, {
      headers: { 'x-goog-api-key': cle },
      signal: AbortSignal.timeout(5_000),
      ...viaLigneGoogle,
    }).then((r) => r.arrayBuffer()).catch(() => undefined);
  };
  toucher();
  const minuterie = setInterval(toucher, intervalleMs);
  minuterie.unref();
  return () => clearInterval(minuterie);
}
