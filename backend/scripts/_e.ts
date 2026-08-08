import { createClient } from '@supabase/supabase-js';
const db = createClient(process.env['SUPABASE_URL']!, process.env['SUPABASE_SERVICE_ROLE_KEY']!,
  { auth: { persistSession: false, autoRefreshToken: false } });

console.log('=== migrations en base ===');
for (const [nom, appel] of [
  ['0020 browsable_categories', () => db.rpc('browsable_categories')],
  ['0021 merchant_open_now', () => db.rpc('merchant_open_now', { p_merchant_id: '00000000-0000-0000-0000-000000000000' })],
  ['0022 category_merchants', () => db.rpc('category_merchants', { p_category_id: '00000000-0000-0000-0000-000000000000' })],
  ['0023 search_products', () => db.rpc('search_products', { query_text: 'tacos', query_embedding: null })],
] as const) {
  const { error } = await appel();
  console.log(`  ${nom.padEnd(28)} ${error ? `✗ ${error.message.slice(0, 50)}` : '✓'}`);
}

const { data } = await db.rpc('search_products', { query_text: 'tacos', query_embedding: null });
const l = (data ?? []) as any[];
console.log(`\nrecherche « tacos » : ${l.length} résultats`);
for (const p of l.slice(0, 4)) {
  console.log(`  ${String(p.merchant_open ? 'ouvert ' : 'fermé  ')} ${String(p.name).slice(0, 34).padEnd(36)} ${p.merchant_name}`);
}
