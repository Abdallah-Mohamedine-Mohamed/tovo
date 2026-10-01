// Ce qu'Overture Maps contient pour Niamey (lecture seule, S3 public, ~30 s).
//
//   npm i --no-save @duckdb/node-api
//   node scripts/commerces/extraire-overture.mjs [version]   → overture-niamey.json
//   npx tsx scripts/commerces/construire.ts overture-niamey.json
//
// Versions : https://overturemaps-us-west-2.s3.amazonaws.com/?list-type=2&prefix=release/&delimiter=/
// Données sous licence CDLA Permissive 2.0 (Overture Maps Foundation).
import { DuckDBInstance } from '@duckdb/node-api';
import { writeFileSync } from 'node:fs';

const RELEASE = process.argv[2] ?? '2026-09-23.1';
const db = await DuckDBInstance.create(':memory:');
const c = await db.connect();
await c.run("INSTALL httpfs; LOAD httpfs; INSTALL spatial; LOAD spatial; SET s3_region='us-west-2';");

// Niamey et sa périphérie.
const bbox = 'bbox.xmin > 1.95 AND bbox.xmax < 2.25 AND bbox.ymin > 13.40 AND bbox.ymax < 13.65';
const debut = Date.now();
await c.run(`CREATE TABLE lieux AS
  SELECT id, names.primary AS nom, basic_category AS categorie, taxonomy.primary AS detail, operating_status AS statut, confidence,
         phones, websites, socials, addresses[1].freeform AS adresse,
         ST_X(geometry) AS lng, ST_Y(geometry) AS lat, sources[1].dataset AS source
  FROM read_parquet('s3://overturemaps-us-west-2/release/${RELEASE}/theme=places/type=place/*', hive_partitioning=1)
  WHERE ${bbox}`).catch(async (e) => {
  // Sans l'extension spatiale, la géométrie se lit en WKB : on la charge.
  await c.run('INSTALL spatial; LOAD spatial;');
  await c.run(`CREATE TABLE lieux AS
    SELECT id, names.primary AS nom, basic_category AS categorie, taxonomy.primary AS detail, operating_status AS statut, confidence,
           phones, websites, socials, addresses[1].freeform AS adresse,
           ST_X(ST_GeomFromWKB(geometry)) AS lng, ST_Y(ST_GeomFromWKB(geometry)) AS lat, sources[1].dataset AS source
    FROM read_parquet('s3://overturemaps-us-west-2/release/${RELEASE}/theme=places/type=place/*', hive_partitioning=1)
    WHERE ${bbox}`);
});
console.log(`lu en ${Math.round((Date.now() - debut) / 1000)} s`);

const lire = async (sql) => (await c.runAndReadAll(sql)).getRowObjectsJson();
console.log(await lire(`SELECT count(*) total,
  count(*) FILTER (WHERE confidence >= 0.7) fiables,
  count(*) FILTER (WHERE phones IS NOT NULL AND len(phones) > 0) avec_telephone,
  count(*) FILTER (WHERE socials IS NOT NULL AND len(socials) > 0) avec_facebook
  FROM lieux`));
console.log(await lire(`SELECT categorie, count(*) n FROM lieux GROUP BY 1 ORDER BY 2 DESC LIMIT 30`));
console.log(await lire(`SELECT nom, categorie, round(confidence, 2) conf FROM lieux
  WHERE detail ILIKE '%restaurant%' OR detail ILIKE '%butcher%' OR detail ILIKE '%grocery%' OR detail ILIKE '%supermarket%' OR detail ILIKE '%meat%'
  ORDER BY confidence DESC LIMIT 25`));
console.log(await lire('SELECT source, count(*) n FROM lieux GROUP BY 1 ORDER BY 2 DESC'));
console.log(await lire('SELECT statut, count(*) n FROM lieux GROUP BY 1'));
writeFileSync('overture-niamey.json', JSON.stringify(await lire('SELECT * FROM lieux'), null, 1));
console.log('→ overture-niamey.json');
