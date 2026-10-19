/**
 * Cherche des photos de produits dans les BASES PUBLIQUES (14/10) :
 * Open Beauty Facts (cosmétiques), Open Food Facts (confiserie, boissons),
 * Open Products Facts (accessoires). Pour chaque article sans image, garde
 * jusqu'à 4 fiches candidates (nom, marque, contenance, photo de face) et
 * télécharge leurs photos pour comparaison. RIEN n'est choisi ici : chaque
 * candidate est vérifiée à l'œil contre la photo de la boutique.
 *
 *   node scripts/visite-catalogue/candidats-publics.mjs <dossier catalogue> <sortie> [marque1,marque2,…]
 *
 * Photos sous licence CC BY-SA (Open Beauty Facts…) : la source est gardée
 * pour la citer.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const [DOSSIER, SORTIE, MARQUES] = process.argv.slice(2);
mkdirSync(join(SORTIE, 'photos'), { recursive: true });
const marques = (MARQUES ?? '').split(',').map((m) => m.trim().toLowerCase()).filter(Boolean);

function lireCsv(texte) {
  const lignes = []; let ligne = [], champ = '', q = false;
  texte = texte.replace(/^﻿/, '');
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i];
    if (q) { if (c === '"') { if (texte[i + 1] === '"') { champ += '"'; i++; } else q = false; } else champ += c; }
    else if (c === '"') q = true; else if (c === ';') { ligne.push(champ); champ = ''; }
    else if (c === '\n') { ligne.push(champ.replace(/\r$/, '')); lignes.push(ligne); ligne = []; champ = ''; }
    else champ += c;
  }
  if (champ || ligne.length) { ligne.push(champ); lignes.push(ligne); }
  const [h, ...r] = lignes.filter((l) => l.length > 1);
  return r.map((l) => Object.fromEntries(h.map((k, i) => [k, (l[i] ?? '').trim()])));
}

const images = new Set(readdirSync(join(DOSSIER, 'images')));
const articles = lireCsv(readFileSync(join(DOSSIER, 'inventaire.csv'), 'utf8'))
  .filter((a) => !images.has(`${a.id}.jpg`))
  .filter((a) => marques.length === 0 || marques.includes((a.marque || '').toLowerCase()));

const BASES = ['world.openbeautyfacts.org', 'world.openfoodfacts.org', 'world.openproductsfacts.org'];
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
// Les mots qui n'aident pas la recherche (contenance, mots de liaison).
const termes = (a) => `${a.marque} ${a.nom.replace(new RegExp(a.marque, 'i'), '')}`
  .replace(/\b\d+([.,]\d+)?\s?(ml|g|kg|l|oz|cl)\b/gi, ' ').replace(/[–—()·,]/g, ' ').replace(/\s+/g, ' ').trim();

const resultats = existsSync(join(SORTIE, 'candidats.json')) ? JSON.parse(readFileSync(join(SORTIE, 'candidats.json'), 'utf8')) : {};
for (const a of articles) {
  if (resultats[a.id]) continue;
  const q = termes(a);
  const candidats = [];
  for (const base of BASES) {
    try {
      const r = await fetch(`https://${base}/cgi/search.pl?search_terms=${encodeURIComponent(q)}&search_simple=1&json=1&page_size=8&fields=code,product_name,brands,quantity,image_front_url`, {
        headers: { 'user-agent': 'Tovo-catalogue/1.0 (catalogue boutique)' }, signal: AbortSignal.timeout(25_000),
      });
      const j = await r.json();
      for (const p of j.products ?? []) {
        if (!p.image_front_url) continue;
        // La marque doit correspondre : on n'ouvre pas les fiches d'une autre marque.
        if (!(p.brands ?? '').toLowerCase().includes((a.marque || '').toLowerCase().split(' ')[0])) continue;
        candidats.push({ base, code: p.code, nom: p.product_name ?? '', marque: p.brands ?? '', contenance: p.quantity ?? '',
          image: p.image_front_url, grande: p.image_front_url.replace(/\.(\d+)\.jpg$/, '.full.jpg') });
      }
    } catch { /* base lente ou indisponible : on passe */ }
    await pause(700);
    if (candidats.length >= 4) break;
  }
  const gardes = candidats.slice(0, 4);
  for (const [i, c] of gardes.entries()) {
    try {
      const r = await fetch(c.image, { signal: AbortSignal.timeout(20_000) });
      if (r.ok) { c.fichier = `${a.id}-${i + 1}.jpg`; writeFileSync(join(SORTIE, 'photos', c.fichier), Buffer.from(await r.arrayBuffer())); }
    } catch { /* photo indisponible */ }
  }
  resultats[a.id] = { nom: a.nom, marque: a.marque, contenance: a.contenance, photo_source: a.photo_source, recherche: q, candidats: gardes };
  writeFileSync(join(SORTIE, 'candidats.json'), JSON.stringify(resultats, null, 1));
  console.log(`${a.id} ${a.nom} → ${gardes.length} candidate(s)`);
}
console.log(`Terminé : ${Object.values(resultats).filter((r) => r.candidats.length).length} / ${Object.keys(resultats).length} articles avec au moins une candidate.`);
