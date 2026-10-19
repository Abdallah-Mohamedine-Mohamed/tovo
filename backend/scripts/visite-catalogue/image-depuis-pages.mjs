/**
 * Récupère la photo principale d'un produit depuis des pages de revendeurs ou
 * de marques (balise og:image, ou fiche JSON d'une boutique Shopify), et la
 * télécharge pour comparaison (14/10).
 *
 *   node image-depuis-pages.mjs <dossier sortie> <id> <url page 1> [<url page 2> …]
 *
 * Écrit <id>-web-1.jpg, <id>-web-2.jpg… et affiche la source de chacune.
 * Rien n'est choisi ici : chaque image est vérifiée à l'œil.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const [SORTIE, ID, ...PAGES] = process.argv.slice(2);
mkdirSync(SORTIE, { recursive: true });
const ENTETES = { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36', accept: 'text/html,image/*,*/*' };

async function imagesDe(page) {
  if (/\.(jpe?g|png|webp)(\?|$)/i.test(page)) return [page];
  // Boutique Shopify : la fiche produit JSON donne les photos du produit, et rien d'autre.
  if (/\/products\/[^/?#]+$/.test(page)) {
    try {
      const j = await (await fetch(`${page}.json`, { headers: ENTETES, signal: AbortSignal.timeout(25_000) })).json();
      const srcs = (j.product?.images ?? []).map((i) => i.src).filter(Boolean);
      if (srcs.length) return srcs.slice(0, 3);
    } catch { /* pas une boutique Shopify : on lit la page */ }
  }
  const r = await fetch(page, { headers: ENTETES, redirect: 'follow', signal: AbortSignal.timeout(25_000) });
  // Page absente ou redirigée ailleurs (produit retiré) : ses images ne sont pas celles du produit.
  // Une redirection vers une autre FICHE produit (chemin détaillé) est acceptée ;
  // vers l'accueil ou une liste, non.
  const arrivee = new URL(r.url).pathname.replace(/\/$/, '');
  const redirigeAilleurs = arrivee !== new URL(page).pathname.replace(/\/$/, '')
    && (arrivee.split('/').filter(Boolean).length < 3 || /search|collections?$|categor/i.test(arrivee));
  if (!r.ok || redirigeAilleurs) {
    console.log(`page indisponible ou redirigée : ${page}`);
    return [];
  }
  const html = await r.text();
  const trouvees = [];
  for (const m of html.matchAll(/<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image)["'][^>]*>/gi)) {
    const c = /content=["']([^"']+)["']/i.exec(m[0]);
    if (c) trouvees.push(c[1]);
  }
  // Données produit structurées (JSON-LD), seulement s'il n'y a pas d'og:image :
  // ailleurs dans la page, « image » désigne souvent d'autres produits.
  if (trouvees.length === 0) for (const m of html.matchAll(/"image"\s*:\s*(\[[^\]]*\]|"[^"]+")/g)) {
    try { const v = JSON.parse(m[1]); for (const u of [].concat(v)) if (typeof u === 'string') trouvees.push(u); } catch { /* ignoré */ }
  }
  // og:image d'abord ; jamais un logo ou une icône du site.
  return [...new Set(trouvees.map((u) => new URL(u.replace(/&amp;/g, '&'), page).href))]
    .filter((u) => !/logo|favicon|sprite|placeholder/i.test(u)).slice(0, 2);
}

let n = 0;
for (const page of PAGES) {
  try {
    for (let url of await imagesDe(page)) {
      // Shopify : une version plus grande de la même image.
      if (/cdn\/shop\//.test(url) && !/[?&]width=/.test(url)) url += (url.includes('?') ? '&' : '?') + 'width=1200';
      const r = await fetch(url, { headers: ENTETES, signal: AbortSignal.timeout(25_000) });
      const type = r.headers.get('content-type') ?? '';
      if (!r.ok || !type.startsWith('image/')) continue;
      const octets = Buffer.from(await r.arrayBuffer());
      if (octets.length < 8000) continue; // icône, pas une photo produit
      n++;
      const fichier = `${ID}-web-${n}.${type.includes('png') ? 'png' : type.includes('webp') ? 'webp' : 'jpg'}`;
      writeFileSync(join(SORTIE, fichier), octets);
      console.log(`${fichier}\t${Math.round(octets.length / 1024)} Ko\t${url}\t(page ${page})`);
    }
  } catch (e) {
    console.log(`échec ${page} : ${e.message}`);
  }
}
if (n === 0) console.log('aucune image récupérée');
