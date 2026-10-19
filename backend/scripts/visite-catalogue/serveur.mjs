/**
 * VISITE CATALOGUE (14/10) — saisir sur place, chez le commerçant, les prix et
 * les corrections d'un inventaire préparé à l'avance (inventaire.csv).
 *
 *   node scripts/visite-catalogue/serveur.mjs "C:\Users\abdal\Documents\niger beaute catalogue"
 *   puis ouvrir http://localhost:4300
 *
 * Tourne sur le PC, SANS Internet (sauf la recherche par code-barres). Rien à
 * installer. L'inventaire n'est JAMAIS modifié : chaque saisie va dans
 * visite.json (copie de secours à chaque écriture), et l'export final
 * (catalogue-final.csv) fusionne les deux.
 *
 * Le dossier contient : inventaire.csv, images\ (photos produit),
 * photos-boutique\ (photos du magasin en JPEG) ; la visite y ajoute
 * visite.json et photos-visite\.
 */
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, renameSync, copyFileSync } from 'node:fs';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const DOSSIER = process.argv[2] ?? process.cwd();
const PORT = Number(process.env.PORT ?? 4300);
const ICI = dirname(fileURLToPath(import.meta.url));
const FICHIER_VISITE = join(DOSSIER, 'visite.json');
const PHOTOS_VISITE = join(DOSSIER, 'photos-visite');
mkdirSync(PHOTOS_VISITE, { recursive: true });

// --- CSV (point-virgule, champs entre guillemets) -----------------------------
function lireCsv(texte) {
  const lignes = [];
  let ligne = [], champ = '', guillemets = false;
  texte = texte.replace(/^\uFEFF/, '');
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i];
    if (guillemets) {
      if (c === '"') { if (texte[i + 1] === '"') { champ += '"'; i++; } else guillemets = false; } else champ += c;
    } else if (c === '"') guillemets = true;
    else if (c === ';') { ligne.push(champ); champ = ''; }
    else if (c === '\n') { ligne.push(champ.replace(/\r$/, '')); lignes.push(ligne); ligne = []; champ = ''; }
    else champ += c;
  }
  if (champ || ligne.length) { ligne.push(champ); lignes.push(ligne); }
  const [entete, ...reste] = lignes.filter((l) => l.length > 1);
  return reste.map((l) => Object.fromEntries(entete.map((k, i) => [k.trim(), (l[i] ?? '').trim()])));
}
const champCsv = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;

// --- Données ----------------------------------------------------------------
const inventaire = lireCsv(readFileSync(join(DOSSIER, 'inventaire.csv'), 'utf8'));
const images = new Set(existsSync(join(DOSSIER, 'images')) ? readdirSync(join(DOSSIER, 'images')) : []);
// Les remarques de la recherche d'images (images\sources-claude.csv) : pourquoi
// une image a été refusée, ou ce qu'il faut vérifier sur place.
const remarquesImages = new Map(
  (existsSync(join(DOSSIER, 'images', 'sources-claude.csv'))
    ? lireCsv(readFileSync(join(DOSSIER, 'images', 'sources-claude.csv'), 'utf8')) : [])
    .filter((r) => r.verdict === 'refus' || /vérifier|confirmer|CORRECTION/i.test(r.remarque ?? ''))
    .map((r) => [r.id, r.remarque]),
);

function lireVisite() {
  if (!existsSync(FICHIER_VISITE)) return { articles: {}, ajouts: [] };
  return JSON.parse(readFileSync(FICHIER_VISITE, 'utf8'));
}
let visite = lireVisite();
/** Écriture sûre : fichier temporaire puis remplacement, et une copie de secours. */
function ecrireVisite() {
  const tmp = `${FICHIER_VISITE}.tmp`;
  writeFileSync(tmp, JSON.stringify(visite, null, 1), 'utf8');
  if (existsSync(FICHIER_VISITE)) copyFileSync(FICHIER_VISITE, `${FICHIER_VISITE}.secours`);
  renameSync(tmp, FICHIER_VISITE);
}

const CHAMPS = ['nom', 'marque', 'contenance', 'variante', 'categorie', 'sous_categorie', 'prix', 'statut', 'code_barres', 'note', 'photo'];
function articles() {
  const deBase = inventaire.map((a) => ({
    ...a,
    image: images.has(`${a.id}.jpg`) ? `/images/${a.id}.jpg` : null,
    note_images: remarquesImages.get(a.id) ?? '',
    ajout: false,
    ...(visite.articles[a.id] ?? {}),
  }));
  return [...deBase, ...visite.ajouts.map((a) => ({ ...a, ajout: true }))];
}

function exporter() {
  const colonnes = ['id', 'photo_source', 'nom', 'marque', 'gamme', 'contenance', 'variante', 'categorie', 'sous_categorie',
    'nouvelle_categorie', 'description', 'mots_cles', 'imitation', 'confiance', 'a_verifier', 'prix', 'statut', 'code_barres',
    'note', 'image', 'photo_visite', 'ajout'];
  const lignes = articles().map((a) => colonnes.map((k) => champCsv(
    k === 'image' ? (a.image ? a.image.replace('/images/', '') : '')
      : k === 'photo_visite' ? (a.photo ?? '')
        : k === 'ajout' ? (a.ajout ? 'oui' : 'non')
          : k === 'statut' ? (a.statut ?? 'a_faire')
            : a[k] ?? '')).join(';'));
  return '\uFEFF' + [colonnes.join(';'), ...lignes].join('\r\n');
}

// --- Code-barres : Open Beauty Facts, puis Open Food Facts --------------------
async function chercherCodeBarres(code) {
  for (const base of ['world.openbeautyfacts.org', 'world.openfoodfacts.org']) {
    try {
      const r = await fetch(`https://${base}/api/v2/product/${encodeURIComponent(code)}.json?fields=product_name,brands,quantity,image_front_url`, {
        headers: { 'user-agent': 'Tovo-visite-catalogue/1.0' }, signal: AbortSignal.timeout(8000),
      });
      const j = await r.json();
      if (j.status === 1 && j.product) {
        return { trouve: true, source: base.split('.')[1], nom: j.product.product_name ?? '', marque: j.product.brands ?? '',
          contenance: j.product.quantity ?? '', image: j.product.image_front_url ?? null };
      }
    } catch { /* hors ligne, ou lent : on essaie la base suivante */ }
  }
  return { trouve: false };
}

// --- Serveur ----------------------------------------------------------------
const TYPES = { '.html': 'text/html; charset=utf-8', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp' };
const lireCorps = (req) => new Promise((ok, ko) => {
  const morceaux = []; let taille = 0;
  req.on('data', (m) => { taille += m.length; if (taille > 25e6) { ko(new Error('trop gros')); req.destroy(); } else morceaux.push(m); });
  req.on('end', () => ok(Buffer.concat(morceaux)));
  req.on('error', ko);
});
const json = (res, code, corps) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(corps)); };

function fichierStatique(res, dossier, nom) {
  const propre = decodeURIComponent(nom).replace(/[\\/]|\.\./g, '');
  const chemin = join(DOSSIER, dossier, propre);
  if (!existsSync(chemin)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': TYPES[extname(chemin).toLowerCase()] ?? 'application/octet-stream', 'cache-control': 'max-age=3600' });
  res.end(readFileSync(chemin));
}

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname;
    if (p === '/' && req.method === 'GET') {
      res.writeHead(200, { 'content-type': TYPES['.html'] });
      return res.end(readFileSync(join(ICI, 'page.html')));
    }
    if (p === '/api/donnees') return json(res, 200, { articles: articles(), dossier: DOSSIER });
    for (const d of ['images', 'photos-boutique', 'photos-visite']) {
      if (p.startsWith(`/${d}/`)) return fichierStatique(res, d, p.slice(d.length + 2));
    }
    // Enregistrer un article (champ par champ ; une valeur vide efface la correction).
    let m = /^\/api\/article\/([\w-]+)$/.exec(p);
    if (m && req.method === 'PUT') {
      const id = m[1];
      const corps = JSON.parse((await lireCorps(req)).toString('utf8'));
      const valeurs = Object.fromEntries(Object.entries(corps).filter(([k]) => CHAMPS.includes(k)));
      const ajout = visite.ajouts.find((a) => a.id === id);
      if (ajout) Object.assign(ajout, valeurs, { maj: new Date().toISOString() });
      else if (inventaire.some((a) => a.id === id)) visite.articles[id] = { ...(visite.articles[id] ?? {}), ...valeurs, maj: new Date().toISOString() };
      else return json(res, 404, { erreur: 'article inconnu' });
      ecrireVisite();
      return json(res, 200, { ok: true });
    }
    // Un article manquant de l'inventaire.
    if (p === '/api/ajout' && req.method === 'POST') {
      const corps = JSON.parse((await lireCorps(req)).toString('utf8'));
      const n = visite.ajouts.length + 1;
      const id = `NB-M${String(n).padStart(3, '0')}`;
      visite.ajouts.push({ id, photo_source: corps.photo_source ?? '', confiance: 'visite', statut: 'fait',
        ...Object.fromEntries(Object.entries(corps).filter(([k]) => CHAMPS.includes(k))), maj: new Date().toISOString() });
      ecrireVisite();
      return json(res, 200, { ok: true, id });
    }
    // Une photo jointe à un article (fichier envoyé tel quel).
    m = /^\/api\/photo\/([\w-]+)$/.exec(p);
    if (m && req.method === 'POST') {
      const ext = ({ 'image/png': '.png', 'image/webp': '.webp' })[req.headers['content-type']] ?? '.jpg';
      const nom = `${m[1]}-${Date.now()}${ext}`;
      writeFileSync(join(PHOTOS_VISITE, nom), await lireCorps(req));
      return json(res, 200, { ok: true, photo: nom });
    }
    m = /^\/api\/codebarres\/(\d{6,14})$/.exec(p);
    if (m) return json(res, 200, await chercherCodeBarres(m[1]));
    if (p === '/api/export') {
      const csv = exporter();
      writeFileSync(join(DOSSIER, 'catalogue-final.csv'), csv, 'utf8');
      res.writeHead(200, { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="catalogue-final.csv"' });
      return res.end(csv);
    }
    res.writeHead(404); res.end();
  } catch (e) {
    json(res, 500, { erreur: e.message });
  }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Visite catalogue : ${inventaire.length} articles (${DOSSIER})`);
  console.log(`Ouvrir http://localhost:${PORT}`);
});
