import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';
import { vector } from '@electric-sql/pglite-pgvector';
import { anonClient } from '../src/services/supabase.js';
import { boutiquesCorrespondantes } from '../src/ai/intents.js';
import type { CataloguePage } from '../src/services/catalogue.js';

const source = anonClient();
const local = new PGlite({ extensions: { vector } });

async function readAll(table: string, fields: string) {
  const rows: Record<string, unknown>[] = [];
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await source.from(table).select(fields).order('id').range(offset, offset + 499);
    if (error) throw error;
    rows.push(...data as unknown as Record<string, unknown>[]);
    if (data.length < 500) return rows;
  }
}

try {
  const [merchants, categories, products] = await Promise.all([
    readAll('merchants', 'id,name,is_approved,is_open'),
    readAll('categories', 'id,name,parent_id,slug'),
    readAll('products', 'id,merchant_id,category_id,name,price,is_available,options_text'),
  ]);
  await local.exec(readFileSync('tests/fixtures/catalogue.sql', 'utf8'));
  await local.exec(readFileSync('../supabase/migrations/0050_catalogue_pagine.sql', 'utf8'));
  await local.exec('begin');
  for (const row of merchants) await local.query('insert into merchants values ($1,$2,$3,$4)', [row.id, row.name, row.is_approved, row.is_open]);
  for (const row of categories) await local.query('insert into categories values ($1,$2,$3,$4)', [row.id, row.name, row.parent_id, row.slug]);
  for (const row of products) await local.query('insert into products(id,merchant_id,category_id,name,price,is_available,options_text) values ($1,$2,$3,$4,$5,$6,$7)',
    [row.id, row.merchant_id, row.category_id, row.name, row.price, row.is_available, row.options_text]);
  await local.exec('commit');
  const reports = [];
  for (const query of ['poulet', 'tacos aux boulettes', 'attieke', 'souris']) {
    const ids = new Set<string>();
    let offset = 0;
    let count = 0;
    for (;;) {
      const result = await local.query<{ page: CataloguePage }>('select catalog_products_page(p_query => $1, p_offset => $2, p_limit => 24) as page', [query, offset]);
      const page = result.rows[0]!.page;
      count = page.total;
      for (const product of page.items) { assert(!ids.has(product.id)); ids.add(product.id); }
      if (page.next_offset === null) break;
      offset = page.next_offset;
    }
    assert.equal(ids.size, count);
    if (query === 'poulet') assert(count > 8);
    reports.push({ query, total: count, unique: ids.size });
  }
  const named = merchants as unknown as Array<{ id: string; name: string }>;
  for (const name of ["Garba d'or", 'otakoss centre aere', 'otakoss nouveau marche']) {
    const matches = boutiquesCorrespondantes(name, named);
    assert.equal(matches.length, 1);
    const merchant = matches[0]!;
    const result = await local.query<{ page: CataloguePage }>('select catalog_products_page(p_merchants => $1, p_limit => 60) as page', [[merchant.id]]);
    const page = result.rows[0]!.page;
    assert(page.items.every((product) => product.merchant_id === merchant.id));
    const expected = products.filter((product) => product.merchant_id === merchant.id && product.is_available).length;
    assert.equal(page.total, expected);
    reports.push({ merchant: merchant.name, total: page.total, categories: new Set(products.filter((product) => product.merchant_id === merchant.id && product.is_available).map((product) => product.category_id)).size });
  }
  console.log(JSON.stringify({ verification: 'Lecture publique Supabase, SQL exécuté uniquement en mémoire locale', products: products.length, reports }, null, 2));
} finally {
  await local.close();
}
