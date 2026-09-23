import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { vector } from '@electric-sql/pglite-pgvector';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { fuzzystrmatch } from '@electric-sql/pglite/contrib/fuzzystrmatch';

/**
 * Migration 0056 : trouver le produit même mal écrit, sans rien trouver
 * quand le catalogue n'a vraiment rien.
 */
const db = new PGlite({ extensions: { vector, pg_trgm, fuzzystrmatch } });
const boutique = randomUUID();

beforeAll(async () => {
  await db.exec(readFileSync('tests/fixtures/catalogue.sql', 'utf8'));
  await db.exec('create table platform_settings(id int primary key default 1)');
  await db.exec(readFileSync('../supabase/migrations/0056_variantes_et_fautes.sql', 'utf8'));
  // 0057 : la même recherche, précalculée. Le comportement doit être identique.
  await db.exec(readFileSync('../supabase/migrations/0057_recherche_precalculee.sql', 'utf8'));
  // 0058 : un mot juste, un mot de travers.
  await db.exec(readFileSync('../supabase/migrations/0058_un_mot_de_travers.sql', 'utf8'));
  await db.query('insert into merchants values ($1, $2, true, true)', [boutique, 'Maquis Test']);
  for (const [nom, variantes] of [
    ['Attiéké poulet', null],
    ['Pizza Crevette', null],
    ['Nuggets (14 Pièces )', null],
    ['Doukounou', 'dukunu ; doukounnou'],
    ['Riz gras', null],
    ['Jus de bissap', null],
    // Aucune variante : c'est la règle phonétique seule qui doit les trouver.
    ['Doukounou (5 pièces)', null],
    ['Kilichi', null],
    ['Gâteau chocolat', null],
    ['Double Burger', null],
    ['Pain Poulet', null],
    ['Brochettes de poulet', null],
  ] as const) {
    await db.query(
      'insert into products(id, merchant_id, name, price, search_aliases) values ($1, $2, $3, 1000, $4)',
      [randomUUID(), boutique, nom, variantes],
    );
  }
});
afterAll(() => db.close());

async function chercher(q: string) {
  const r = await db.query<{ page: { items: Array<{ name: string }>; match_type: string; total: number } }>(
    'select catalog_products_page($1, null, null, null, 0, 8) as page', [q]);
  return r.rows[0]!.page;
}

describe('recherche tolérante aux fautes (0056)', () => {
  it('une lettre de travers : « pizza rcevette » trouve la Pizza Crevette', async () => {
    const page = await chercher('pizza rcevette');
    expect(page.items[0]?.name).toBe('Pizza Crevette');
    expect(page.match_type).toBe('similar');
  });

  it('écriture de client : « atieke », « nougets 14 pieces »', async () => {
    expect((await chercher('atieke')).items.map((i) => i.name)).toContain('Attiéké poulet');
    expect((await chercher('nougets 14 pieces')).items.map((i) => i.name)).toContain('Nuggets (14 Pièces )');
  });

  it('une variante enregistrée compte comme le nom : correspondance exacte', async () => {
    const page = await chercher('dukunu');
    expect(page.items[0]?.name).toBe('Doukounou');
    expect(page.match_type).toBe('exact');
  });

  it('se prononce pareil : trouvé sans aucune variante enregistrée', async () => {
    for (const [q, attendu] of [
      ['doucounou', 'Doukounou (5 pièces)'],
      ['dukunu', 'Doukounou (5 pièces)'],
      ['kilishi', 'Kilichi'],
      ['gato chocolat', 'Gâteau chocolat'],
      ['nuggets', 'Nuggets (14 Pièces )'],
    ] as const) {
      const page = await chercher(q);
      expect(page.items.map((i) => i.name), q).toContain(attendu);
      expect(page.match_type, q).toBe('exact');
    }
  });

  it('un mot juste, un mot de travers (0058)', async () => {
    for (const [q, attendu] of [
      ['doble burger', 'Double Burger'],
      ['pan poulet', 'Pain Poulet'],
      ['broshet poulet', 'Brochettes de poulet'],
    ] as const) {
      expect((await chercher(q)).items.map((i) => i.name), q).toContain(attendu);
    }
    // « bain » ne passe pas l'étape mot à mot (première lettre différente) :
    // seul le dernier recours le rapproche de « pain », et le présente comme
    // une SUGGESTION proche, jamais comme le produit demandé.
    expect((await chercher('bain poulet')).match_type).toBe('similar');
  });

  it('bien écrit : inchangé, exact d’abord', async () => {
    const page = await chercher('riz gras');
    expect(page.items.map((i) => i.name)).toEqual(['Riz gras']);
    expect(page.match_type).toBe('exact');
  });

  it('ce que le catalogue n’a pas : toujours rien, pas d’invention', async () => {
    for (const q of ['iphone', 'voiture rouge', 'ordinateur portable', 'xq']) {
      expect((await chercher(q)).total, q).toBe(0);
    }
  });
});
