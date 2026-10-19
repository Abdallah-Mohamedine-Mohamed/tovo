/**
 * Fiches de recherche de TOUT le catalogue (19/10) — voir
 * src/services/ficheRecherche.ts. Niger Beauté est exclue : ses fiches
 * viennent de scripts/niger-beaute/decrire.ts (même consigne d'origine).
 *
 *   npx tsx --env-file=.env scripts/recherche/fiches.ts              → écrit scripts/recherche/fiches.json (à relire)
 *   npx tsx --env-file=.env scripts/recherche/fiches.ts --appliquer  → écrit aussi en base
 *
 * Reprenable : un produit déjà dans fiches.json n'est pas redemandé.
 * En base : description = fiche ; tags = étiquettes ; search_aliases =
 * variantes existantes + étiquettes + contenance. L'indexeur réindexe ensuite
 * (le texte indexé change).
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { redigerFiche, variantesAvecFiche, type Fiche } from '../../src/services/ficheRecherche.js';

const appliquer = process.argv.includes('--appliquer');
const SORTIE = 'scripts/recherche/fiches.json';
const PARALLELE = 8;
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

interface Ligne {
  id: string; name: string; description: string | null; image_url: string | null; options_text: string | null; search_aliases: string | null;
  legacy_id: string | null; merchants: { name: string } | null; categories: { name: string } | null;
}
const produits: Ligne[] = [];
for (let page = 0; ; page++) {
  const { data, error } = await db.from('products')
    .select('id, name, description, image_url, options_text, search_aliases, legacy_id, merchants(name), categories(name)')
    .order('id').range(page * 1000, page * 1000 + 999);
  if (error) throw error;
  produits.push(...(data as unknown as Ligne[]));
  if (data.length < 1000) break;
}
const cibles = produits.filter((p) => !String(p.legacy_id ?? '').startsWith('niger-beaute:'));

const fiches: Record<string, Fiche & { nom: string }> = existsSync(SORTIE) ? JSON.parse(readFileSync(SORTIE, 'utf8')) : {};
const LIMITE = Number(process.argv[process.argv.indexOf('--limite') + 1]) || Infinity;
const aFaire = cibles.filter((p) => !fiches[p.id]).filter((_, i, t) => i % Math.max(1, Math.floor(t.length / LIMITE)) === 0).slice(0, LIMITE);
console.log(`${cibles.length} produits hors Niger Beauté, ${aFaire.length} fiches à écrire.`);

let faites = 0, echecs = 0;
const file = [...aFaire];
await Promise.all(Array.from({ length: PARALLELE }, async () => {
  for (let p = file.shift(); p; p = file.shift()) {
    for (let essai = 1; essai <= 3; essai++) {
      try {
        const fiche = await redigerFiche({
          name: p.name, boutique: p.merchants?.name, rayon: p.categories?.name, options: p.options_text, image_url: p.image_url,
        });
        fiches[p.id] = { nom: p.name, ...fiche };
        break;
      } catch (cause) {
        if (essai === 3) { echecs++; console.log(`\n✗ ${p.name} : ${(cause as Error).message.slice(0, 120)}`); }
        else await new Promise((ok) => setTimeout(ok, 4000 * essai));
      }
    }
    // Écrit à chaque fiche : une coupure ne perd rien.
    writeFileSync(SORTIE, JSON.stringify(fiches, null, 1));
    process.stdout.write(`\r  ${++faites}/${aFaire.length}`);
  }
}));
console.log(`\n✓ ${aFaire.length - echecs} fiches écrites, ${echecs} échecs.`);

if (appliquer) {
  let ecrits = 0;
  for (const p of cibles) {
    const fiche = fiches[p.id];
    // Déjà écrite (reprise après coupure) : rien à refaire.
    if (!fiche || !fiche.description || p.description === fiche.description) continue;
    const { error } = await db.from('products').update({
      description: fiche.description,
      tags: fiche.etiquettes.slice(0, 20),
      search_aliases: variantesAvecFiche(p.search_aliases, fiche, p.name),
    }).eq('id', p.id);
    if (error) console.log(`✗ ${p.name} : ${error.message}`);
    else ecrits++;
  }
  console.log(`✓ ${ecrits} produits mis à jour en base.`);
}
