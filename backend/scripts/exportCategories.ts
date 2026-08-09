/**
 * Exporte l'arborescence des catégories, pour le travail d'iconographie.
 *
 * Les compteurs ne sont pas décoratifs : ils disent lesquelles méritent une
 * icône dessinée et lesquelles n'en verront jamais l'usage. Une catégorie à
 * zéro produit ET zéro boutique n'apparaît nulle part dans l'application.
 */
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const db = createClient(process.env['SUPABASE_URL']!, process.env['SUPABASE_SERVICE_ROLE_KEY']!,
  { auth: { persistSession: false, autoRefreshToken: false } });

interface Cat { id: string; parent_id: string | null; name: string; slug: string; icon: string | null; sort_order: number | null; is_active: boolean }

const { data: cats, error } = await db.from('categories')
  .select('id, parent_id, name, slug, icon, sort_order, is_active').order('sort_order');
if (error) throw new Error(error.message);
const toutes = (cats ?? []) as Cat[];

// Comptages en une passe : 177 requêtes séparées seraient inutilement lentes.
const produits = new Map<string, number>();
const boutiques = new Map<string, number>();
for (const table of ['products', 'merchants'] as const) {
  const cible = table === 'products' ? produits : boutiques;
  let de = 0;
  for (;;) {
    const page = await db.from(table).select('category_id').range(de, de + 999);
    if (page.error) throw new Error(page.error.message);
    for (const l of page.data ?? []) {
      const c = (l as { category_id: string | null }).category_id;
      if (c) cible.set(c, (cible.get(c) ?? 0) + 1);
    }
    if ((page.data?.length ?? 0) < 1000) break;
    de += 1000;
  }
}

const enfants = new Map<string | null, Cat[]>();
for (const c of toutes) {
  const l = enfants.get(c.parent_id) ?? [];
  l.push(c); enfants.set(c.parent_id, l);
}

const lignes: string[] = ['module,categorie,slug,icone_actuelle,produits,boutiques,active'];
const md: string[] = [];
const racines = enfants.get(null) ?? [];

for (const r of racines) {
  const fils = enfants.get(r.id) ?? [];
  const pTot = (produits.get(r.id) ?? 0) + fils.reduce((s, f) => s + (produits.get(f.id) ?? 0), 0);
  const bTot = (boutiques.get(r.id) ?? 0) + fils.reduce((s, f) => s + (boutiques.get(f.id) ?? 0), 0);
  md.push(`\n## ${r.icon ?? '·'} ${r.name}  —  ${fils.length} sous-catégories, ${pTot} produits, ${bTot} boutiques`);
  lignes.push(`,${JSON.stringify(r.name)},${r.slug},${r.icon ?? ''},${produits.get(r.id) ?? 0},${boutiques.get(r.id) ?? 0},${r.is_active}`);
  for (const f of fils) {
    const p = produits.get(f.id) ?? 0, b = boutiques.get(f.id) ?? 0;
    md.push(`  - ${f.icon ?? '·'} ${f.name}  (${p} produits, ${b} boutiques)${f.is_active ? '' : '  [inactive]'}`);
    lignes.push(`${JSON.stringify(r.name)},${JSON.stringify(f.name)},${f.slug},${f.icon ?? ''},${p},${b},${f.is_active}`);
  }
}

writeFileSync('../categories.csv', lignes.join('\n'), 'utf8');
console.log(md.join('\n'));
console.log(`\n${racines.length} modules, ${toutes.length} catégories au total. CSV écrit dans categories.csv`);
process.exit(0);
