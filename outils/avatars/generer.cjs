// Génère les images des avatars pour la carte de l'appli (07/10), comme les
// 144 vues de la moto du suivi : chaque animation (arrêt, marche, course,
// salut) × 24 directions × 4 inclinaisons de caméra, en bandes WebP
// transparentes, plus manifest.json (cycles, foulées, ancrage).
//
//   cd outils/avatars && npm install && node generer.cjs [femme capuche …]
//
// Il faut Google Chrome installé (rendu 3D sans fenêtre). Voir LISEZMOI.md.
const http = require('http');
const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');

const ICI = __dirname;
// Les personnages (Quaternius, domaine public CC0).
const GLB = Object.fromEntries(['femme', 'capuche', 'aventurier', 'homme'].map((k) => [k, path.join(ICI, 'modeles', k + '.glb')]));
const CHROME = process.env.CHROME ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const FICHIERS = {
  '/sprites.html': path.join(ICI, 'rendu.html'),
  '/three.min.js': path.join(ICI, 'node_modules', 'three', 'build', 'three.min.js'),
  '/GLTFLoader.js': path.join(ICI, 'node_modules', 'three', 'examples', 'js', 'loaders', 'GLTFLoader.js'),
  ...Object.fromEntries(Object.entries(GLB).map(([k, f]) => [`/avatar/${k}.glb`, f])),
};
// Les animations, le nombre d'images par cycle, et la vitesse « naturelle »
// (m/s pour un avatar de 1,75 m) : la foulée = vitesse × durée du cycle.
const ANIMS = { Idle: { images: 8 }, Walk: { images: 12, vitesse: 1.35 }, Run: { images: 10, vitesse: 3.9 }, Wave: { images: 12 } };
const INCLINAISONS = [0, 30, 45, 60];
const DIRECTIONS = 24; // tous les 15°
const SORTIE = path.join(ICI, 'images');

async function main() {
  const liste = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(GLB);
  const serveur = http.createServer((req, res) => {
    const f = FICHIERS[decodeURIComponent(req.url.split('?')[0])];
    if (!f) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'content-type': f.endsWith('.html') ? 'text/html' : f.endsWith('.js') ? 'text/javascript' : 'application/octet-stream' });
    fs.createReadStream(f).pipe(res);
  }).listen(0);
  const navigateur = await puppeteer.launch({
    executablePath: CHROME, headless: true,
    args: ['--enable-webgl', '--ignore-gpu-blocklist', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await navigateur.newPage();
  page.on('pageerror', (e) => console.log('[erreur page]', e.message));
  const manifest = { taille: 240, ancrage: { x: 0.5, y: 0.851, sens: 'point de contact au sol, en fraction de l’image' }, directions: DIRECTIONS, pas_direction: 360 / DIRECTIONS,
    inclinaisons: INCLINAISONS, direction_0: 'l’avatar s’éloigne vers le haut de l’écran ; 90 = vers la droite (cap relatif à la caméra)', avatars: {} };
  for (const cle of liste) {
    await page.goto(`http://localhost:${serveur.address().port}/sprites.html`, { waitUntil: 'networkidle0' });
    await page.waitForFunction('window.pret === true');
    const durees = await page.evaluate((c) => window.charger(c), cle);
    const dossier = path.join(SORTIE, cle);
    fs.rmSync(dossier, { recursive: true, force: true });
    fs.mkdirSync(dossier, { recursive: true });
    const info = {};
    const debut = Date.now();
    let octets = 0, n = 0;
    for (const [anim, { images, vitesse }] of Object.entries(ANIMS)) {
      if (durees[anim] == null) continue;
      info[anim] = { images, duree_cycle_s: +durees[anim].toFixed(4), ...(vitesse ? { vitesse_naturelle_ms: vitesse, foulee_m: +(vitesse * durees[anim]).toFixed(3) } : {}) };
      for (const t of INCLINAISONS) {
        for (let d = 0; d < DIRECTIONS; d++) {
          const deg = Math.round((d * 360) / DIRECTIONS);
          const url = await page.evaluate((a, i, dd, im) => window.bande(a, i, dd, im), anim, t, deg, images);
          const b = Buffer.from(url.split(',')[1], 'base64');
          fs.writeFileSync(path.join(dossier, `${anim.toLowerCase()}_t${t}_${String(deg).padStart(3, '0')}.webp`), b);
          octets += b.length; n++;
        }
      }
    }
    manifest.avatars[cle] = info;
    console.log(`${cle} : ${n} bandes, ${(octets / 1024 / 1024).toFixed(1)} Mo, ${Math.round((Date.now() - debut) / 1000)} s — ${Object.keys(info).join(', ')}`);
  }
  fs.mkdirSync(SORTIE, { recursive: true });
  const ancien = fs.existsSync(path.join(SORTIE, 'manifest.json')) ? JSON.parse(fs.readFileSync(path.join(SORTIE, 'manifest.json'), 'utf8')) : { avatars: {} };
  manifest.avatars = { ...ancien.avatars, ...manifest.avatars };
  fs.writeFileSync(path.join(SORTIE, 'manifest.json'), JSON.stringify(manifest, null, 2));
  await navigateur.close();
  serveur.close();
}
main().catch((e) => { console.error(e); process.exit(1); });
