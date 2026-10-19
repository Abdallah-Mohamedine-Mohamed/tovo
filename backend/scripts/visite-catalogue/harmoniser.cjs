/**
 * Harmonise des photos produit (14/10) : le fond (uni, blanc ou gris clair,
 * repéré depuis les BORDS de l'image) devient blanc pur, le produit est
 * recadré, puis centré sur un carré blanc de 1200 × 1200, à 80 % de sa plus
 * grande dimension. Même rendu pour tout le catalogue.
 *
 * Lancé par Electron (lit et écrit les images, rien à installer) :
 *   electron harmoniser.cjs <entrée> <sortie.jpg> [<entrée> <sortie> …]
 *
 * Le fond n'est effacé que depuis les bords (remplissage), jamais à
 * l'intérieur du produit : un flacon blanc garde son blanc. Une photo au
 * fond chargé (rayon) n'est que recadrée et centrée.
 */
const { app, BrowserWindow } = require('electron');
const { readFileSync, writeFileSync } = require('node:fs');
const { extname } = require('node:path');

app.disableHardwareAcceleration();
app.on('window-all-closed', () => {});

const TRAITEMENT = `async (src, cote, part) => {
  const img = await new Promise((ok, ko) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => ko(new Error('image illisible')); i.src = src; });
  const w = img.naturalWidth, h = img.naturalHeight;
  const c = new OffscreenCanvas(w, h); const x = c.getContext('2d');
  x.fillStyle = '#fff'; x.fillRect(0, 0, w, h); x.drawImage(img, 0, 0);
  const d = x.getImageData(0, 0, w, h); const p = d.data;
  // La couleur du fond : la médiane des pixels du bord.
  const bord = [];
  for (let i = 0; i < w; i++) bord.push(i, (h - 1) * w + i);
  for (let j = 0; j < h; j++) bord.push(j * w, j * w + w - 1);
  const med = (k) => { const v = bord.map((i) => p[i * 4 + k]).sort((a, b) => a - b); return v[v.length >> 1]; };
  const fond = [med(0), med(1), med(2)];
  const fondClair = fond.every((v) => v > 200);
  // Déjà blanc : on ne touche à rien, on recadre seulement (un produit blanc garde ses bords).
  const dejaBlanc = fond.every((v) => v >= 238);
  const proche = (i, tol) => Math.abs(p[i] - fond[0]) + Math.abs(p[i + 1] - fond[1]) + Math.abs(p[i + 2] - fond[2]) <= tol;
  const efface = new Uint8Array(w * h);
  if (fondClair && !dejaBlanc) {
    // Remplissage depuis les bords : seulement le fond relié au bord.
    const pile = [];
    for (const i of bord) if (!efface[i] && proche(i * 4, 24)) { efface[i] = 1; pile.push(i); }
    while (pile.length) {
      const i = pile.pop(); const px = i % w, py = (i / w) | 0;
      for (const n of [px > 0 ? i - 1 : -1, px < w - 1 ? i + 1 : -1, py > 0 ? i - w : -1, py < h - 1 ? i + w : -1]) {
        if (n >= 0 && !efface[n] && proche(n * 4, 24)) { efface[n] = 1; pile.push(n); }
      }
    }
    for (let i = 0; i < w * h; i++) if (efface[i]) { p[i * 4] = p[i * 4 + 1] = p[i * 4 + 2] = 255; }
    x.putImageData(d, 0, 0);
  }
  // Le cadre du produit : ce qui n'a pas été effacé.
  let x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) {
    const k = j * w + i;
    const garde = dejaBlanc ? (p[k * 4] < 242 || p[k * 4 + 1] < 242 || p[k * 4 + 2] < 242) : fondClair ? !efface[k] : true;
    if (garde) { if (i < x0) x0 = i; if (i > x1) x1 = i; if (j < y0) y0 = j; if (j > y1) y1 = j; }
  }
  if (x1 < 0) { x0 = 0; y0 = 0; x1 = w - 1; y1 = h - 1; }
  const cw = x1 - x0 + 1, ch = y1 - y0 + 1;
  const e = Math.min((cote * part) / cw, (cote * part) / ch);
  const sortie = new OffscreenCanvas(cote, cote); const s = sortie.getContext('2d');
  s.fillStyle = '#fff'; s.fillRect(0, 0, cote, cote);
  s.imageSmoothingQuality = 'high';
  s.drawImage(c, x0, y0, cw, ch, (cote - cw * e) / 2, (cote - ch * e) / 2, cw * e, ch * e);
  const blob = await sortie.convertToBlob({ type: 'image/jpeg', quality: 0.92 });
  const octets = new Uint8Array(await blob.arrayBuffer());
  let b = ''; for (let i = 0; i < octets.length; i += 32768) b += String.fromCharCode(...octets.subarray(i, i + 32768));
  return { jpeg: btoa(b), fondClair, cadre: [x0, y0, cw, ch], taille: [w, h] };
}`;

const MIME = { '.png': 'image/png', '.webp': 'image/webp', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg' };

app.whenReady().then(async () => {
  const args = process.argv.slice(process.argv.findIndex((a) => a.endsWith('harmoniser.cjs')) + 1);
  const w = new BrowserWindow({ show: false, webPreferences: { offscreen: true } });
  await w.loadURL('about:blank');
  for (let i = 0; i + 1 < args.length; i += 2) {
    const [entree, sortie] = [args[i], args[i + 1]];
    try {
      const src = `data:${MIME[extname(entree).toLowerCase()] ?? 'image/jpeg'};base64,${readFileSync(entree).toString('base64')}`;
      const r = await w.webContents.executeJavaScript(`(${TRAITEMENT})(${JSON.stringify(src)}, 1200, 0.8)`);
      writeFileSync(sortie, Buffer.from(r.jpeg, 'base64'));
      console.log(`ok ${sortie} (fond ${r.fondClair ? 'clair effacé' : 'chargé, conservé'})`);
    } catch (e) {
      console.log(`echec ${entree} : ${e.message}`);
    }
  }
  app.quit();
});
