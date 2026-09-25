import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';

const appliquer = process.argv.includes('--appliquer');
const limiteArg = process.argv.find((arg) => arg.startsWith('--limite='));
const limite = limiteArg ? Number(limiteArg.split('=')[1]) : Infinity;

if ((limite !== Infinity && !Number.isInteger(limite)) || limite < 1) {
  throw new Error('--limite doit être un entier positif');
}

const db = createClient(
  process.env['SUPABASE_URL']!,
  process.env['SUPABASE_SERVICE_ROLE_KEY']!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: enseignes, error } = await db
  .from('merchants')
  .select('id, name, logo_url')
  .not('logo_url', 'is', null)
  .order('name');
if (error) throw error;

let modifies = 0;
let ignores = 0;
let erreurs = 0;

for (const enseigne of (enseignes ?? []).slice(0, limite)) {
  const url = enseigne.logo_url as string;
  const marqueur = '/storage/v1/object/public/products/';
  const chemin = url.includes(marqueur)
    ? decodeURIComponent(url.split(marqueur)[1]!.split('?')[0]!)
    : null;
  if (!chemin?.endsWith('.webp') || chemin.endsWith('-net.webp')) {
    ignores++;
    continue;
  }

  const original = chemin.replace(/\.webp$/i, '.png');
  const nouveau = chemin.replace(/\.webp$/i, '-net.webp');
  try {
    const { data: fichier, error: erreurSource } = await db.storage.from('products').download(original);
    if (erreurSource || !fichier) throw erreurSource ?? new Error('Source absente');
    const source = Buffer.from(await fichier.arrayBuffer());
    const dimensions = await sharp(source).metadata();
    if (!dimensions.width || !dimensions.height) throw new Error('Dimensions inconnues');

    let resultat: Buffer | null = null;
    let largeur = dimensions.width;
    let hauteur = dimensions.height;
    for (const [taille, qualite] of [[1000, 90], [800, 86], [600, 82]]) {
      const candidat = await sharp(source)
        .resize({ width: taille, height: taille, fit: 'inside', withoutEnlargement: true })
        .sharpen({ sigma: 0.5, m1: 0.3, m2: 1 })
        .webp({ quality: qualite, effort: 6, smartSubsample: true })
        .toBuffer();
      resultat = candidat;
      const metadonnees = await sharp(candidat).metadata();
      largeur = metadonnees.width!;
      hauteur = metadonnees.height!;
      if (candidat.byteLength <= 100 * 1024) break;
    }
    if (!resultat) throw new Error('Conversion impossible');
    if (resultat.byteLength > 100 * 1024) {
      console.log(`${enseigne.name}: conservé, impossible de rester sous 100 Ko`);
      ignores++;
      continue;
    }

    const precedent = await fetch(url);
    if (!precedent.ok) throw new Error(`Logo actuel indisponible : ${precedent.status}`);
    const tailleActuelle = (await precedent.arrayBuffer()).byteLength;
    const gain = Math.round((1 - resultat.byteLength / tailleActuelle) * 100);
    console.log(`${enseigne.name}: ${dimensions.width}×${dimensions.height} → ${largeur}×${hauteur}, ${Math.round(tailleActuelle / 1024)} → ${Math.round(resultat.byteLength / 1024)} Ko (${gain}% de gain)`);

    if (appliquer) {
      const { error: erreurEnvoi } = await db.storage.from('products').upload(nouveau, resultat, {
        contentType: 'image/webp',
        upsert: true,
      });
      if (erreurEnvoi) throw erreurEnvoi;
      const { data: publicUrl } = db.storage.from('products').getPublicUrl(nouveau);
      const { data: miseAJour, error: erreurMaj } = await db.from('merchants')
        .update({ logo_url: publicUrl.publicUrl })
        .eq('id', enseigne.id)
        .eq('logo_url', url)
        .select('id')
        .single();
      if (erreurMaj || !miseAJour) throw erreurMaj ?? new Error('Logo modifié simultanément');
    }
    modifies++;
  } catch (cause) {
    erreurs++;
    console.error(`${enseigne.name}: ${(cause as Error).message}`);
  }
}

console.log(`${appliquer ? 'Modifiés' : 'Prêts'} : ${modifies}, ignorés : ${ignores}, erreurs : ${erreurs}`);
if (erreurs) process.exitCode = 1;
