// Publie les images des avatars (images/) dans le stockage Supabase, espace
// public « avatars » : l'appli télécharge seulement les bandes dont elle a
// besoin, puis les garde sur le téléphone. À relancer après generer.cjs.
//
//   node publier.cjs            (lit SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY
//                                dans backend/.env)
const fs = require('fs');
const path = require('path');

const ICI = __dirname;
const IMAGES = path.join(ICI, 'images');
const env = Object.fromEntries(
  fs.readFileSync(path.join(ICI, '..', '..', 'backend', '.env'), 'utf8')
    .split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).trim()]),
);
const URL_ = process.env.SUPABASE_URL ?? env.SUPABASE_URL;
const CLE = process.env.SUPABASE_SERVICE_ROLE_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY;
if (!URL_ || !CLE) throw new Error('SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY manquant');
const entetes = { Authorization: `Bearer ${CLE}`, apikey: CLE };

async function main() {
  // L'espace public (créé s'il n'existe pas).
  const b = await fetch(`${URL_}/storage/v1/bucket`, {
    method: 'POST', headers: { ...entetes, 'content-type': 'application/json' },
    body: JSON.stringify({ id: 'avatars', name: 'avatars', public: true }),
  });
  if (!b.ok && b.status !== 409 && !/already exists|Duplicate/i.test(await b.text())) throw new Error('espace avatars : ' + b.status);
  const fichiers = [];
  for (const a of fs.readdirSync(IMAGES)) {
    const p = path.join(IMAGES, a);
    if (fs.statSync(p).isDirectory()) for (const f of fs.readdirSync(p)) fichiers.push(`${a}/${f}`);
    else fichiers.push(a);
  }
  let faits = 0, erreurs = 0;
  const file = [...fichiers];
  await Promise.all(Array.from({ length: 8 }, async () => {
    for (let f = file.shift(); f; f = file.shift()) {
      for (let essai = 1; essai <= 3; essai++) {
        const r = await fetch(`${URL_}/storage/v1/object/avatars/${f}`, {
          method: 'POST',
          headers: { ...entetes, 'content-type': f.endsWith('.json') ? 'application/json' : 'image/webp',
            'x-upsert': 'true', 'cache-control': f.endsWith('.json') ? 'max-age=300' : 'max-age=31536000' },
          body: fs.readFileSync(path.join(IMAGES, f)),
        }).catch(() => null);
        if (r?.ok) { faits++; break; }
        if (essai === 3) { erreurs++; console.log('échec', f, r?.status); }
      }
      if ((faits + erreurs) % 200 === 0) console.log(`  ${faits + erreurs} / ${fichiers.length}`);
    }
  }));
  console.log(`${faits} fichiers publiés, ${erreurs} échecs → ${URL_}/storage/v1/object/public/avatars/`);
}
main().catch((e) => { console.error(e.message); process.exit(1); });
