import { defineConfig } from 'vitest/config';
import { readFileSync } from 'node:fs';

/**
 * Les tests RLS parlent à un vrai projet Supabase (staging). Ils sont donc
 * lents et séquentiels : deux fichiers en parallèle se marcheraient dessus sur
 * les zones et les livreurs partagés.
 */

// Charge .env sans dépendance supplémentaire.
try {
  for (const line of readFileSync('.env', 'utf8').split('\n')) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (!match) continue;
    const [, key, rawValue] = match;
    if (!key || process.env[key] !== undefined) continue;
    process.env[key] = rawValue?.replace(/^["']|["']$/g, '') ?? '';
  }
} catch {
  // Pas de .env : normal en CI, où les variables viennent de l'environnement.
  // Ailleurs, c'est presque toujours l'explication d'un échec — autant le dire.
  if (!process.env.CI) {
    console.warn('[vitest] backend/.env introuvable — les variables doivent venir de l\'environnement.');
  }
}

// Les tests ne parlent JAMAIS à Nita par accident.
//
// Un achat en ligne créé pendant un test est un vrai achat sur le compte
// Nita de Tovo : il apparaît dans les relevés, il reste payable, et une suite
// de tests lancée dix fois en laisse dix. Les identifiants sont donc retirés
// de l'environnement de test, ce qui suffit à désactiver le paiement mobile.
// `NITA_LIVE_TEST=1` les rétablit, pour une vérification manuelle assumée.
if (!process.env.NITA_LIVE_TEST) {
  for (const cle of ['NITA_USERNAME', 'NITA_PASSWORD', 'NITA_API_KEY', 'NITA_BASE_URL']) {
    delete process.env[cle];
  }
}

export default defineConfig({
  test: {
    environment: 'node',
    testTimeout: 30_000,
    hookTimeout: 60_000,
    fileParallelism: false,
    sequence: { concurrent: false },
  },
});
