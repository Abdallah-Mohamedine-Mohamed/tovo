/**
 * Banc de recherche, étape 2 : le client tape mal, trouve-t-il quand même ?
 *
 *   npm run recherche:banc              → voie rapide (celle du fil de discussion)
 *   npm run recherche:banc -- --sens    → ajoute la recherche par le sens
 *                                         (embeddings), sur un échantillon
 *
 * Réussi = le produit visé est dans les 8 premiers résultats ; l'enseigne
 * visée est reconnue par le rapprochement de noms. Mêmes fonctions que le
 * serveur (cataloguePage, boutiquesCorrespondantes). Lecture seule.
 */
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { cataloguePage } from '../../src/services/catalogue.js';
import { boutiquesCorrespondantes, normaliserIntention } from '../../src/ai/intents.js';
import type { Requete } from './generer.js';

const avecSens = process.argv.includes('--sens');
const requetes = JSON.parse(readFileSync('scripts/recherche/requetes.json', 'utf8')) as Requete[];
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const { data: enseignes, error } = await db.from('merchants').select('id, name, search_aliases').eq('is_approved', true);
// La colonne d'alias n'existe qu'après la migration 0056 : sans elle, on
// mesure l'état actuel.
const boutiques = error
  ? ((await db.from('merchants').select('id, name').eq('is_approved', true)).data ?? [])
  : (enseignes ?? []);

const pareil = (a: string, b: string) => normaliserIntention(a) === normaliserIntention(b);

async function trouveProduit(r: Requete, sens: boolean): Promise<boolean> {
  try {
    const page = await cataloguePage(db, { q: r.requete, limit: 8 }, sens);
    return page.items.slice(0, 8).some((item) => pareil(String(item.name), r.cible));
  } catch {
    return false;
  }
}

async function enParallele<T, R>(t: T[], n: number, f: (e: T) => Promise<R>): Promise<R[]> {
  const sortie: R[] = new Array(t.length);
  let k = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (k < t.length) { const i = k++; sortie[i] = await f(t[i]!); } }));
  return sortie;
}

const pct = (a: number, b: number) => (b ? `${Math.round((100 * a) / b)} %` : '—');

const produits = requetes.filter((r) => r.type === 'produit');
const rapides = await enParallele(produits, 6, (r) => trouveProduit(r, false));

console.log(`\n=== Produits, voie rapide — ${produits.length} requêtes ===`);
for (const source of ['frappe', 'gemini'] as const) {
  const idx = produits.map((r, i) => [r, i] as const).filter(([r]) => r.source === source);
  const ok = idx.filter(([, i]) => rapides[i]).length;
  console.log(`  ${source.padEnd(7)} trouvés ${pct(ok, idx.length).padStart(5)}  (${ok}/${idx.length})`);
}
const rates = produits.filter((_, i) => !rapides[i]);
console.log('  Exemples ratés :');
for (const r of rates.filter((_, i) => i % Math.max(1, Math.floor(rates.length / 12)) === 0).slice(0, 12)) {
  console.log(`    ✗ « ${r.requete} » → ${r.cible}`);
}

if (avecSens) {
  // Échantillon : chaque requête coûte un embedding, sur le même quota que l'app.
  const echantillon = produits.filter((_, i) => i % 4 === 0);
  const sens = await enParallele(echantillon, 2, (r) => trouveProduit(r, true));
  const ok = sens.filter(Boolean).length;
  console.log(`\n=== Produits, avec le sens (embeddings) — échantillon de ${echantillon.length} ===`);
  console.log(`  trouvés ${pct(ok, echantillon.length)}  (${ok}/${echantillon.length})`);
}

const enseignesR = requetes.filter((r) => r.type === 'boutique');
const trouvees = enseignesR.map((r) => {
  const avecAlias = boutiques.flatMap((b) => [
    { id: b.id as string, name: b.name as string },
    ...String((b as { search_aliases?: string | null }).search_aliases ?? '')
      .split(/[,;\n]/).map((a) => a.trim()).filter(Boolean)
      .map((alias) => ({ id: b.id as string, name: alias })),
  ]);
  const cible = boutiques.find((b) => pareil(b.name as string, r.cible))?.id;
  return boutiquesCorrespondantes(r.requete, avecAlias).some((b) => b.id === cible);
});
console.log(`\n=== Enseignes — ${enseignesR.length} requêtes ===`);
for (const source of ['frappe', 'gemini'] as const) {
  const idx = enseignesR.map((r, i) => [r, i] as const).filter(([r]) => r.source === source);
  const ok = idx.filter(([, i]) => trouvees[i]).length;
  console.log(`  ${source.padEnd(7)} reconnues ${pct(ok, idx.length).padStart(5)}  (${ok}/${idx.length})`);
}
for (const [r] of enseignesR.map((r, i) => [r, i] as const).filter(([, i]) => !trouvees[i]).slice(0, 8)) {
  console.log(`    ✗ « ${r.requete} » → ${r.cible}`);
}
