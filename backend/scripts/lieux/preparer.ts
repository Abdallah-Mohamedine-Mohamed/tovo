/**
 * Prépare les lieux de Niamey depuis un export OpenStreetMap (Overpass, JSON
 * « out center tags »), vers backend/data/lieux-niamey.json.
 *
 *   npx tsx scripts/lieux/preparer.ts <export-overpass.json>
 *
 * La requête Overpass utilisée (boîte 13.40,1.95 → 13.65,2.30) : quartiers et
 * villages (place), repères nommés (amenity, shop, tourism, leisure, office,
 * bâtiments publics) et rues nommées (highway). Données © les contributeurs
 * d'OpenStreetMap, licence ODbL.
 */
import { readFileSync, writeFileSync } from 'node:fs';

const { normaliserIntention } = await import('../../src/ai/intents.js');

interface Element {
  type: string; id: number; lat?: number; lon?: number;
  center?: { lat: number; lon: number }; tags?: Record<string, string>;
}

const source = process.argv[2];
if (!source) throw new Error('chemin de l’export Overpass manquant');
const elements = (JSON.parse(readFileSync(source, 'utf8')) as { elements: Element[] }).elements;

function genre(t: Record<string, string>): string {
  if (t.place) return ['suburb', 'neighbourhood', 'quarter'].includes(t.place) ? 'quartier' : 'village';
  if (t.highway) return 'rue';
  const a = t.amenity;
  if (a === 'pharmacy') return 'pharmacie';
  if (a === 'marketplace') return 'marché';
  if (a === 'place_of_worship') return t.religion === 'muslim' ? 'mosquée' : t.religion === 'christian' ? 'église' : 'lieu de culte';
  if (['school', 'college', 'university', 'kindergarten'].includes(a ?? '')) return 'école';
  if (['hospital', 'clinic', 'doctors', 'dentist'].includes(a ?? '')) return 'santé';
  if (a === 'fuel') return 'station-service';
  if (['bank', 'money_transfer', 'atm', 'bureau_de_change'].includes(a ?? '')) return 'banque';
  if (['restaurant', 'fast_food', 'cafe', 'bar'].includes(a ?? '')) return 'restaurant';
  if (a === 'bus_station') return 'gare';
  if (a === 'police') return 'police';
  if (t.shop) return t.shop === 'supermarket' ? 'supermarché' : 'boutique';
  if (t.tourism) return t.tourism === 'hotel' ? 'hôtel' : 'tourisme';
  if (t.office) return 'bureau';
  if (t.leisure) return 'loisir';
  return 'repère';
}

const lieux = elements
  .map((e) => {
    const t = e.tags ?? {};
    const nom = (t['name:fr'] ?? t.name ?? '').trim();
    const lat = e.lat ?? e.center?.lat;
    const lng = e.lon ?? e.center?.lon;
    if (!nom || lat === undefined || lng === undefined) return null;
    return { id: `osm:${e.type}/${e.id}`, nom, nom_normalise: normaliserIntention(nom), genre: genre(t), lat, lng };
  })
  .filter((l): l is NonNullable<typeof l> => l !== null);

// Le quartier de chaque lieu : le centre de quartier le plus proche (3 km au plus).
const quartiers = lieux.filter((l) => l.genre === 'quartier' || l.genre === 'village');
const distanceKm = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) => {
  const dLat = (a.lat - b.lat) * 111;
  const dLng = (a.lng - b.lng) * 111 * Math.cos((a.lat * Math.PI) / 180);
  return Math.hypot(dLat, dLng);
};
const avecQuartier = lieux.map((l) => {
  if (l.genre === 'quartier' || l.genre === 'village') return { ...l, quartier: l.nom };
  let meilleur: { nom: string; d: number } | null = null;
  for (const q of quartiers) {
    const d = distanceKm(l, q);
    if (d <= 3 && (!meilleur || d < meilleur.d)) meilleur = { nom: q.nom, d };
  }
  return { ...l, quartier: meilleur?.nom ?? null };
});

// Une rue découpée en plusieurs tronçons : un seul par nom et par quartier.
const vus = new Set<string>();
const uniques = avecQuartier.filter((l) => {
  if (l.genre !== 'rue') return true;
  const cle = `${l.nom_normalise}|${l.quartier ?? ''}`;
  if (vus.has(cle)) return false;
  vus.add(cle);
  return true;
});

writeFileSync('data/lieux-niamey.json', JSON.stringify({
  source: 'OpenStreetMap (Overpass), © les contributeurs d’OpenStreetMap, ODbL',
  prepare_le: new Date().toISOString().slice(0, 10),
  lieux: uniques,
}));
const compte: Record<string, number> = {};
for (const l of uniques) compte[l.genre] = (compte[l.genre] ?? 0) + 1;
console.log(`${uniques.length} lieux → data/lieux-niamey.json`);
console.log(Object.entries(compte).sort((x, y) => y[1] - x[1]).map(([g, n]) => `${g} ${n}`).join(', '));
