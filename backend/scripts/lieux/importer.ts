/**
 * Met les lieux de Niamey en base (table lieux, migration 0068), depuis
 * data/lieux-niamey.json (préparé par scripts/lieux/preparer.ts).
 *
 *   npm run lieux:importer
 *
 * Le serveur n'en a pas besoin pour repérer un lieu (il lit le fichier) :
 * la table sert à l'admin et à la carte. Rejouable : un lieu déjà présent
 * est mis à jour.
 */
import { readFileSync } from 'node:fs';

const { serviceClient } = await import('../../src/services/supabase.js');

const { lieux } = JSON.parse(readFileSync('data/lieux-niamey.json', 'utf8')) as {
  lieux: Array<{ id: string; nom: string; nom_normalise: string; genre: string; quartier: string | null; lat: number; lng: number }>;
};
const db = serviceClient();
for (let i = 0; i < lieux.length; i += 500) {
  const lot = lieux.slice(i, i + 500).map((l) => ({ ...l, source: 'osm', maj_le: new Date().toISOString() }));
  const { error } = await db.from('lieux').upsert(lot, { onConflict: 'id' });
  if (error) throw new Error(`${error.message} — la migration 0068 est-elle appliquée ?`);
}
console.log(`${lieux.length} lieux en base`);
