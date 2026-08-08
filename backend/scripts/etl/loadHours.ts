import { createClient } from '@supabase/supabase-js';
import { parseDump } from './dumpParser.js';

/**
 * Reprend les horaires d'ouverture de 6ammart.
 *
 * 529 lignes pour 76 boutiques, un enregistrement par jour de la semaine.
 * Sans elles, `merchant_open_now` ne s'appuie que sur l'interrupteur du
 * boutiquier — et une boutique reste affichée ouverte à 3 h du matin parce
 * que personne ne pense à la fermer chaque soir.
 *
 * Les deux conventions de jour coïncident : 0 = dimanche des deux côtés,
 * comme `extract(dow)` de Postgres. Rien à convertir, mais il fallait le
 * vérifier — un décalage d'un jour ne se voit qu'au moment où un client
 * trouve tout fermé.
 *
 *   npx tsx --env-file=.env scripts/etl/loadHours.ts <dump.sql> [--apply]
 */

const chemin = process.argv[2];
const appliquer = process.argv.includes('--apply');

if (!chemin) {
  console.error('Usage : tsx scripts/etl/loadHours.ts <dump.sql> [--apply]');
  process.exit(1);
}

const db = createClient(process.env['SUPABASE_URL']!, process.env['SUPABASE_SERVICE_ROLE_KEY']!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Correspondance identifiant 6ammart → identifiant Tovo.
const boutiques = new Map<string, string>();
for (let debut = 0; ; debut += 1000) {
  const { data, error } = await db
    .from('merchants')
    .select('id, legacy_id')
    .not('legacy_id', 'is', null)
    .range(debut, debut + 999);
  if (error) throw error;
  for (const m of data ?? []) boutiques.set(m.legacy_id as string, m.id as string);
  if ((data ?? []).length < 1000) break;
}

const { tables } = await parseDump(chemin, new Set(['store_schedule']));
const lignes = tables.get('store_schedule') ?? [];

interface Horaire {
  merchant_id: string;
  day: number;
  opens_at: string;
  closes_at: string;
}

const horaires: Horaire[] = [];
let sansBoutique = 0;
let invalides = 0;

for (const l of lignes) {
  const merchant = boutiques.get(l.store_id ?? '');
  if (!merchant) {
    // Boutique de démonstration, non migrée.
    sansBoutique++;
    continue;
  }

  const jour = Number(l.day);
  const ouvre = l.opening_time ?? '';
  const ferme = l.closing_time ?? '';

  // Une plage inversée ou vide rendrait la boutique perpétuellement fermée
  // sans qu'aucune erreur ne le signale.
  if (!Number.isInteger(jour) || jour < 0 || jour > 6 || !ouvre || !ferme || ouvre >= ferme) {
    invalides++;
    continue;
  }

  horaires.push({ merchant_id: merchant, day: jour, opens_at: ouvre, closes_at: ferme });
}

console.log(`${lignes.length} horaires dans le dump`);
console.log(`  ${horaires.length} exploitables`);
console.log(`  ${sansBoutique} sur des boutiques non migrées`);
console.log(`  ${invalides} écartés (jour ou plage incohérents)`);
console.log(`  ${new Set(horaires.map((h) => h.merchant_id)).size} boutiques concernées`);

if (!appliquer) {
  console.log('\nMode à blanc : rien écrit. Relancez avec --apply.');
  process.exit(0);
}

let ecrits = 0;
for (let i = 0; i < horaires.length; i += 200) {
  const lot = horaires.slice(i, i + 200);
  // `upsert` sur la contrainte d'unicité : relancer le script ne duplique
  // rien, ce qui compte quand on le rejoue après une coupure.
  const { error } = await db
    .from('merchant_hours')
    .upsert(lot, { onConflict: 'merchant_id,day,opens_at,closes_at', ignoreDuplicates: true });
  if (error) {
    console.error('échec du lot :', error.message);
    process.exit(1);
  }
  ecrits += lot.length;
  process.stdout.write(`\r  ${ecrits}/${horaires.length}`);
}

const { count } = await db.from('merchant_hours').select('*', { count: 'exact', head: true });
console.log(`\n${count} horaires en base.`);
