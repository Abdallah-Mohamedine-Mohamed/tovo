import { createClient } from '@supabase/supabase-js';
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
const { data } = await db.from('products').select('id, name, image_url, is_available').not('image_url', 'is', null).limit(5000);
const lignes = data ?? [];
const statuts = new Map<string, number>(); const exemples: string[] = [];
let n = 0;
for (let i = 0; i < lignes.length; i += 10) {
  const lot = lignes.slice(i, i + 10);
  const r = await Promise.all(lot.map(async (p) => { const res = await fetch(p.image_url as string, { method: 'HEAD' }).catch(() => null); return [p, res?.status ?? 0] as const; }));
  for (const [p, s] of r) { n++; statuts.set(String(s), (statuts.get(String(s)) ?? 0) + 1); if (s !== 200 && exemples.length < 5) exemples.push(`${s} ${p.name} (dispo: ${p.is_available})`); }
}
console.log(`${n} produits avec image_url :`, Object.fromEntries(statuts));
console.log(exemples.join('\n'));
const { count } = await db.from('products').select('*', { count: 'exact', head: true }).is('image_url', null);
console.log(`produits SANS image_url : ${count}`);
