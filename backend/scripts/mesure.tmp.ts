import { createClient } from '@supabase/supabase-js';
import { exigerStaging } from './scenarios/garde.js';
const { url, service } = exigerStaging();
const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
for (const motif of ['%takoss%', '%boba%']) {
  const { data: ms } = await db.from('merchants').select('id, name').ilike('name', motif);
  const noms = new Map<string, Set<string>>();
  for (const m of ms ?? []) {
    const { data: ps } = await db.from('products').select('name, price, categories(name)').eq('merchant_id', m.id);
    for (const p of (ps ?? []) as unknown as Array<{ name: string; price: number; categories: { name: string } | null }>) {
      const k = `${p.name.trim()} | ${p.categories?.name ?? '-'} | ${p.price}`;
      if (!noms.has(k)) noms.set(k, new Set());
      noms.get(k)!.add(m.name.replace(/\s+/g, ' '));
    }
  }
  console.log(`=== ${motif} (${ms?.length} boutiques)`);
  for (const [k, v] of [...noms.entries()].sort()) console.log(`${k} || ${v.size}`);
}
