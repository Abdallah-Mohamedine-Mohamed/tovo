/**
 * Ce que coûte une connexion froide vers Google : le même appel du cerveau,
 * après 1 s de silence (connexion réutilisée) puis après 8 s (connexion
 * fermée par Node au bout de 4 s d'inactivité, à rouvrir).
 *
 *   npx tsx --env-file=.env scripts/banc-ia/connexion.ts
 */
const { comprendre } = await import('../../src/ai/decideur.js');
const { entretenirLigneGoogle } = await import('../../src/lib/ligneGoogle.js');
const { env } = await import('../../src/config/env.js');
const attendre = (ms: number) => new Promise((r) => setTimeout(r, ms));

// --entretien : comme en production (src/index.ts).
if (process.argv.includes('--entretien')) entretenirLigneGoogle(env.GEMINI_API_KEY, 'gemini-3.1-flash-lite');
await comprendre('bonjour');
for (const silence of [1000, 8000, 30000, 8000, 45000, 1000]) {
  await attendre(silence);
  const d = await comprendre('Je veux du poulet');
  console.log(`après ${silence / 1000} s de silence : ${Math.round(d.ms)} ms`);
}
