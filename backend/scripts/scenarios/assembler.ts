/**
 * Assemble tout le SQL d'un projet Supabase neuf en UN fichier, à coller une
 * seule fois dans l'éditeur SQL du projet de test :
 *
 *   schema.sql → migrations/*.sql (ordre numérique) → seed.sql
 *
 *   npm run staging:sql   → écrit supabase/staging/tout-en-un.sql
 *
 * N'exécute rien et ne se connecte à rien.
 */
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const racine = join('..', 'supabase');
const migrations = readdirSync(join(racine, 'migrations'))
  .filter((f) => /^\d{4}_.*\.sql$/.test(f))
  .sort();

const morceaux = [
  ['schema.sql', readFileSync(join(racine, 'schema.sql'), 'utf8')],
  ...migrations.map((f) => [`migrations/${f}`, readFileSync(join(racine, 'migrations', f), 'utf8')]),
  ['seed.sql', readFileSync(join(racine, 'seed.sql'), 'utf8')],
];

const sortie = morceaux
  .map(([nom, sql]) => `-- ${'='.repeat(70)}\n-- ${nom}\n-- ${'='.repeat(70)}\n${sql}\n`)
  .join('\n');

mkdirSync(join(racine, 'staging'), { recursive: true });
writeFileSync(join(racine, 'staging', 'tout-en-un.sql'), sortie);
console.log(`supabase/staging/tout-en-un.sql : schema + ${migrations.length} migrations + seed (${Math.round(sortie.length / 1024)} Ko)`);
