/**
 * Le TYPE de chaque produit (src/services/typeProduit.ts), pour tout le
 * catalogue, Niger Beauté comprise.
 *
 *   npx tsx --env-file=.env scripts/recherche/types.ts              → écrit scripts/recherche/types.json (à relire)
 *   npx tsx --env-file=.env scripts/recherche/types.ts --appliquer  → écrit aussi products.type_produit (migration 0086)
 *
 * Texte seul (nom, boutique, rayon, fiche), 25 produits par appel : moins
 * d'un dollar pour le catalogue. Reprenable : un produit déjà typé n'est pas
 * redemandé.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { typesDesProduits } from '../../src/services/typeProduit.js';

const appliquer = process.argv.includes('--appliquer');
const SORTIE = 'scripts/recherche/types.json';
const PAR_APPEL = 25;
const PARALLELE = 6;
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

interface Ligne {
  id: string; name: string; description: string | null;
  merchants: { name: string } | null; categories: { name: string } | null;
}
const produits: Ligne[] = [];
for (let page = 0; ; page++) {
  const { data, error } = await db.from('products')
    .select('id, name, description, merchants(name), categories(name)')
    .order('id').range(page * 1000, page * 1000 + 999);
  if (error) throw error;
  produits.push(...(data as unknown as Ligne[]));
  if (data.length < 1000) break;
}

const types: Record<string, { nom: string; types: string[] }> = existsSync(SORTIE) ? JSON.parse(readFileSync(SORTIE, 'utf8')) : {};
const aFaire = produits.filter((p) => !types[p.id]);
console.log(`${produits.length} produits, ${aFaire.length} à typer.`);

const lots: Ligne[][] = [];
for (let i = 0; i < aFaire.length; i += PAR_APPEL) lots.push(aFaire.slice(i, i + PAR_APPEL));
let faits = 0, echecs = 0;
await Promise.all(Array.from({ length: PARALLELE }, async () => {
  for (let lot = lots.shift(); lot; lot = lots.shift()) {
    for (let essai = 1; essai <= 3; essai++) {
      try {
        const trouves = await typesDesProduits(lot.map((p) => ({
          id: p.id, name: p.name, boutique: p.merchants?.name, rayon: p.categories?.name, description: p.description,
        })));
        for (const p of lot) {
          const t = trouves.get(p.id);
          if (t) types[p.id] = { nom: p.name, types: t };
        }
        break;
      } catch (cause) {
        if (essai === 3) { echecs += lot.length; console.log(`\n✗ lot : ${(cause as Error).message.slice(0, 120)}`); }
        else await new Promise((ok) => setTimeout(ok, 4000 * essai));
      }
    }
    writeFileSync(SORTIE, JSON.stringify(types, null, 1));
    faits += lot.length;
    process.stdout.write(`\r  ${faits}/${aFaire.length}`);
  }
}));
console.log(`\n✓ ${Object.keys(types).length} produits typés, ${echecs} échecs.`);

if (appliquer) {
  let ecrits = 0;
  for (const p of produits) {
    const t = types[p.id];
    if (!t) continue;
    const { error } = await db.from('products').update({ type_produit: t.types }).eq('id', p.id);
    if (error) { console.log(`✗ ${p.name} : ${error.message}`); break; }
    ecrits++;
  }
  console.log(`✓ ${ecrits} produits mis à jour en base.`);
}
