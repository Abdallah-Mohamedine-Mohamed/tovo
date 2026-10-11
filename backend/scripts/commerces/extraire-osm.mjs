// Les boutiques nommées d'OpenStreetMap à Niamey (shop=*), avec leur type,
// pour construire.ts. Lecture seule, serveur Overpass public (~10 s).
//
//   node scripts/commerces/extraire-osm.mjs   → osm-boutiques-niamey.json
//
// Données © les contributeurs d'OpenStreetMap, licence ODbL. Plusieurs
// serveurs : le principal refuse parfois (406, 500), le suivant répond.
import { writeFileSync } from 'node:fs';

const REQUETE = '[out:json][timeout:90];(nwr["shop"](13.40,1.95,13.65,2.30););out center tags;';
const SERVEURS = [
  'https://overpass-api.de/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

let donnees = null;
for (const url of SERVEURS) {
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json', 'user-agent': 'Tovo-annuaire/1.0' },
      body: new URLSearchParams({ data: REQUETE }),
      signal: AbortSignal.timeout(150_000),
    });
    if (r.ok) { donnees = await r.json(); console.log(`lu sur ${url}`); break; }
    console.log(`${url} : HTTP ${r.status}`);
  } catch (e) {
    console.log(`${url} : ${e.message}`);
  }
}
if (!donnees) throw new Error('aucun serveur Overpass n’a répondu');

const boutiques = donnees.elements
  .map((e) => ({
    id: `${e.type}/${e.id}`,
    nom: (e.tags?.['name:fr'] ?? e.tags?.name ?? '').trim(),
    shop: e.tags?.shop ?? '',
    lat: e.lat ?? e.center?.lat,
    lng: e.lon ?? e.center?.lon,
  }))
  .filter((b) => b.nom && b.lat !== undefined && b.lng !== undefined);
writeFileSync('osm-boutiques-niamey.json', JSON.stringify(boutiques, null, 1));
console.log(`${boutiques.length} boutiques nommées → osm-boutiques-niamey.json`);
