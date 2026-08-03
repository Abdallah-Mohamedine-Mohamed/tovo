import { parseDump, type Row } from './dumpParser.js';

/**
 * Analyse à blanc du dump 6ammart.
 *
 * N'écrit rien. Sert à répondre à trois questions avant toute migration :
 * qu'est-ce qui est réellement exploitable, qu'est-ce qui va poser problème,
 * et combien d'images faudra-t-il transférer.
 *
 *   npx tsx scripts/etl/analyze.ts ~/tovo-migration/tovo-6ammart.sql
 */

const TABLES = new Set([
  'zones',
  'categories',
  'modules',
  'vendors',
  'stores',
  'items',
  'users',
  'delivery_men',
]);

const chemin = process.argv[2];
if (!chemin) {
  console.error('Usage : tsx scripts/etl/analyze.ts <dump.sql>');
  process.exit(1);
}

const { tables } = await parseDump(chemin, TABLES);

const t = (nom: string): Row[] => tables.get(nom) ?? [];
const compte = (lignes: Row[], predicat: (r: Row) => boolean) =>
  lignes.filter(predicat).length;

console.log('\n════ VOLUMES ════');
for (const nom of TABLES) {
  console.log(`${nom.padEnd(14)} ${String(t(nom).length).padStart(6)}`);
}

// ---------------------------------------------------------------------
// Utilisateurs
// ---------------------------------------------------------------------
const users = t('users');
const avecTel = compte(users, (u) => Boolean(u.phone && u.phone.length >= 8));
const telUniques = new Set(users.map((u) => u.phone).filter(Boolean)).size;
const verifies = compte(users, (u) => u.is_phone_verified === '1');

console.log('\n════ UTILISATEURS ════');
console.log(`avec téléphone        ${avecTel} / ${users.length}`);
console.log(`téléphones distincts  ${telUniques}`);
console.log(`téléphones vérifiés   ${verifies}`);
console.log(`avec commandes        ${compte(users, (u) => Number(u.order_count ?? 0) > 0)}`);

// Le format des numéros décide de la migration : Supabase exige du E.164.
const formats = new Map<string, number>();
for (const u of users) {
  if (!u.phone) continue;
  const forme = u.phone.startsWith('+')
    ? `+${u.phone.replace(/\D/g, '').slice(0, 3)}…`
    : `sans + (${u.phone.replace(/\D/g, '').length} chiffres)`;
  formats.set(forme, (formats.get(forme) ?? 0) + 1);
}
console.log('formats de numéro :');
for (const [forme, n] of [...formats].sort((a, b) => b[1] - a[1]).slice(0, 6)) {
  console.log(`  ${forme.padEnd(24)} ${n}`);
}

// ---------------------------------------------------------------------
// Boutiques
// ---------------------------------------------------------------------
const stores = t('stores');
const positionnees = compte(
  stores,
  (s) => Boolean(s.latitude && s.longitude && Number(s.latitude) !== 0),
);

console.log('\n════ BOUTIQUES ════');
console.log(`total                 ${stores.length}`);
console.log(`avec coordonnées      ${positionnees}`);
console.log(`actives               ${compte(stores, (s) => s.status === '1' && s.active === '1')}`);
console.log(`avec logo             ${compte(stores, (s) => Boolean(s.logo))}`);

// ---------------------------------------------------------------------
// Produits
// ---------------------------------------------------------------------
const items = t('items');
const avecOptions = compte(items, (i) => {
  const v = i.variations ?? '';
  const c = i.choice_options ?? '';
  const f = i.food_variations ?? '';
  return [v, c, f].some((s) => s.length > 4 && s !== '[]');
});

console.log('\n════ PRODUITS ════');
console.log(`total                 ${items.length}`);
console.log(`disponibles           ${compte(items, (i) => i.status === '1')}`);
console.log(`avec image            ${compte(items, (i) => Boolean(i.image))}`);
console.log(`avec description      ${compte(items, (i) => Boolean(i.description) && (i.description?.length ?? 0) > 10)}`);
console.log(`avec options          ${avecOptions}`);
console.log(`prix à zéro           ${compte(items, (i) => Number(i.price ?? 0) === 0)}`);

// ---------------------------------------------------------------------
// Ce qui bloquera
// ---------------------------------------------------------------------
console.log('\n════ POINTS DE VIGILANCE ════');

const sansTel = users.length - avecTel;
if (sansTel > 0) {
  console.log(`• ${sansTel} comptes sans téléphone : non migrables (l'identité repose sur le numéro)`);
}
const doublons = avecTel - telUniques;
if (doublons > 0) {
  console.log(`• ${doublons} numéros en double : un seul compte sera conservé par numéro`);
}
const sansCoord = stores.length - positionnees;
if (sansCoord > 0) {
  console.log(`• ${sansCoord} boutiques sans coordonnées : à positionner à la main`);
}

const orphelins = compte(items, (i) => !stores.some((s) => s.id === i.store_id));
if (orphelins > 0) {
  console.log(`• ${orphelins} produits rattachés à une boutique absente : ignorés`);
}

// ---------------------------------------------------------------------
// Images à transférer
// ---------------------------------------------------------------------
const images =
  compte(items, (i) => Boolean(i.image)) +
  compte(stores, (s) => Boolean(s.logo)) +
  compte(stores, (s) => Boolean(s.cover_photo)) +
  compte(t('categories'), (c) => Boolean(c.image));

console.log('\n════ IMAGES ════');
console.log(`fichiers référencés   ${images}`);
console.log('Aucun n’est dans le dump : à récupérer depuis S3 et depuis');
console.log('storage/app/public/ sur le serveur.');
console.log('');
