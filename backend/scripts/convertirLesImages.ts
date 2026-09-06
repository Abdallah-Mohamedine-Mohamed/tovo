/**
 * Convertit en WebP toutes les images servies aux clients, et les
 * redimensionne.
 *
 *     node node_modules/tsx/dist/cli.mjs --env-file=.env scripts/convertirLesImages.ts
 *     ... --essai              n'écrit rien, mesure seulement
 *     ... --limite=50          un lot, pour juger du rendu
 *     ... --cible=merchants    une seule table
 *
 * POURQUOI. Les 2 364 images sont toutes des PNG — mesuré : 60 sur 60 dans
 * l'échantillon. C'est le pire format pour une photographie : le PNG est sans
 * perte, conçu pour des aplats et du texte, et il stocke fidèlement le bruit
 * du capteur qu'aucun client ne verra. Moyenne 125 Ko, 90e centile 385 Ko,
 * jusqu'à 565 Ko pour une vignette large de 300 pixels à l'écran.
 *
 * Sur un réseau nigérien en 3G, un carrousel de huit produits fait payer près
 * d'un mégaoctet de forfait à quelqu'un qui ne fait que survoler.
 *
 * MESURÉ sur cinquante images réparties : 125 Ko deviennent 41 Ko, soit 67 %
 * de moins. Sur les images de plus de 200 Ko, qui sont celles qui font mal :
 * 324 Ko deviennent 70 Ko, soit 78 % de moins.
 *
 * DEUX GAINS CUMULÉS, et le second est souvent le plus gros :
 *
 *   Le FORMAT — WebP à qualité 82 rend une photo indiscernable de l'original
 *   à l'œil, pour une fraction du poids.
 *
 *   LA TAILLE — l'application n'affiche jamais plus large que la moitié d'un
 *   écran de téléphone. Au-delà de 1 000 pixels, chaque pixel transmis est
 *   décodé puis jeté.
 *
 * CE QUI N'EST PAS TOUCHÉ. `search-images` contient les photos que les
 * clients envoient pour chercher — éphémères, jamais réaffichées. `proofs`
 * contient les preuves de livraison : ce sont des pièces justificatives, on
 * n'y touche pas, et elles ne coûtent la bande passante de personne.
 *
 * L'ORIGINAL N'EST PAS SUPPRIMÉ. Le WebP est déposé à côté, et l'URL pointe
 * vers lui. Tant que les anciens fichiers sont là, revenir en arrière est une
 * requête SQL ; les effacer serait irréversible et ne rapporterait que de
 * l'espace de stockage, ce qui coûte le moins cher ici.
 */
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';

/** Au-delà, on transmet des pixels que l'écran ne montrera jamais. */
const COTE_MAX = 1000;

/** 82 : le seuil au-dessus duquel l'œil ne distingue plus, sur des photos. */
const QUALITE = 82;

/** Cinq à la fois : le réseau est le facteur limitant, pas le processeur. */
const PARALLELE = 5;

/**
 * Tout ce qui est servi à un client.
 *
 * Le logo d'une boutique s'affiche en 40 pixels de côté dans une liste, et
 * pèse aujourd'hui autant qu'une photo de plat. C'est le genre d'image qu'on
 * oublie parce qu'elle est petite à l'écran.
 */
const CIBLES: Array<{ table: string; colonne: string }> = [
  { table: 'products', colonne: 'image_url' },
  { table: 'categories', colonne: 'image_url' },
  { table: 'merchants', colonne: 'logo_url' },
  { table: 'merchants', colonne: 'cover_url' },
];

const essai = process.argv.includes('--essai');
const limiteArg = process.argv.find((a) => a.startsWith('--limite='));
const limite = limiteArg ? Number(limiteArg.split('=')[1]) : Infinity;
const cibleArg = process.argv.find((a) => a.startsWith('--cible='));
const cibleVoulue = cibleArg ? cibleArg.split('=')[1] : null;

const db = createClient(
  process.env['SUPABASE_URL']!,
  process.env['SUPABASE_SERVICE_ROLE_KEY']!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

interface Ligne {
  id: string;
  url: string;
  table: string;
  colonne: string;
}

/**
 * Le bucket et le chemin, lus dans l'URL publique.
 *
 * Déduits plutôt que codés en dur : les images produit vivent dans
 * `products`, celles des boutiques et des catégories dans `catalog`. Une URL
 * hébergée ailleurs rend null — on ne peut pas remplacer ce qu'on ne
 * possède pas, et l'ignorer vaut mieux qu'échouer.
 */
function emplacement(url: string): { bucket: string; chemin: string } | null {
  const marqueur = '/storage/v1/object/public/';
  const i = url.indexOf(marqueur);
  if (i < 0) return null;

  const reste = url.slice(i + marqueur.length).split('?')[0]!;
  const coupe = reste.indexOf('/');
  if (coupe < 1) return null;

  return {
    bucket: reste.slice(0, coupe),
    chemin: decodeURIComponent(reste.slice(coupe + 1)),
  };
}

async function aTraiter(): Promise<Ligne[]> {
  const tous: Ligne[] = [];

  for (const cible of CIBLES) {
    if (cibleVoulue && cible.table !== cibleVoulue) continue;

    for (let de = 0; ; de += 1000) {
      const { data, error } = await db
        .from(cible.table)
        .select(`id, ${cible.colonne}`)
        .not(cible.colonne, 'is', null)
        .range(de, de + 999);
      if (error) throw new Error(`${cible.table}.${cible.colonne} : ${error.message}`);

      const lot = (data ?? []) as Array<Record<string, string>>;
      for (const l of lot) {
        const url = l[cible.colonne];
        // Déjà converti : le script se relance sans refaire le travail fait.
        if (!url || url.toLowerCase().includes('.webp')) continue;
        tous.push({ id: l['id']!, url, table: cible.table, colonne: cible.colonne });
      }
      if (lot.length < 1000) break;
    }
  }

  return tous.slice(0, limite);
}

interface Bilan {
  avant: number;
  apres: number;
}

async function convertir(l: Ligne): Promise<Bilan | null> {
  const lieu = emplacement(l.url);
  if (!lieu) return null;

  const { data, error } = await db.storage.from(lieu.bucket).download(lieu.chemin);
  if (error || !data) {
    console.log(`    ✗ ${l.table}.${l.colonne} ${l.id.slice(0, 8)} — ${error?.message ?? 'vide'}`);
    return null;
  }

  const avant = Buffer.from(await data.arrayBuffer());

  let apres: Buffer;
  try {
    apres = await sharp(avant)
      // `withoutEnlargement` : une image déjà petite ne doit pas être
      // agrandie, ce qui la rendrait floue ET plus lourde.
      .resize({ width: COTE_MAX, height: COTE_MAX, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: QUALITE })
      .toBuffer();
  } catch (cause) {
    console.log(`    ✗ ${l.id.slice(0, 8)} — conversion : ${(cause as Error).message.slice(0, 50)}`);
    return null;
  }

  // Le WebP plus lourd que l'original arrive : une image minuscule, ou déjà
  // très compressée. On garde alors ce qui existe.
  if (apres.byteLength >= avant.byteLength) {
    return { avant: avant.byteLength, apres: avant.byteLength };
  }

  if (essai) return { avant: avant.byteLength, apres: apres.byteLength };

  const nouveau = lieu.chemin.replace(/\.[a-z0-9]+$/i, '') + '.webp';

  const { error: erreurEnvoi } = await db.storage
    .from(lieu.bucket)
    .upload(nouveau, apres, { contentType: 'image/webp', upsert: true });
  if (erreurEnvoi) {
    console.log(`    ✗ ${l.id.slice(0, 8)} — envoi : ${erreurEnvoi.message.slice(0, 50)}`);
    return null;
  }

  const { data: pub } = db.storage.from(lieu.bucket).getPublicUrl(nouveau);

  // L'URL n'est mise à jour QU'APRÈS un envoi réussi. Dans l'ordre inverse,
  // une coupure laisserait la ligne pointant vers un fichier inexistant.
  const { error: erreurMaj } = await db
    .from(l.table)
    .update({ [l.colonne]: pub.publicUrl })
    .eq('id', l.id);
  if (erreurMaj) {
    console.log(`    ✗ ${l.id.slice(0, 8)} — mise à jour : ${erreurMaj.message.slice(0, 50)}`);
    return null;
  }

  return { avant: avant.byteLength, apres: apres.byteLength };
}

const lignes = await aTraiter();
const mo = (n: number) => `${(n / 1024 / 1024).toFixed(1)} Mo`;

const parTable = new Map<string, number>();
for (const l of lignes) {
  const cle = `${l.table}.${l.colonne}`;
  parTable.set(cle, (parTable.get(cle) ?? 0) + 1);
}
console.log(`  ${lignes.length} image(s) à convertir${essai ? '  — ESSAI, rien ne sera écrit' : ''}`);
for (const [cle, n] of parTable) console.log(`    ${String(n).padStart(5)}  ${cle}`);

if (lignes.length === 0) {
  console.log('  Rien à faire.');
  process.exit(0);
}

const debut = Date.now();
let faits = 0;
let avant = 0;
let apres = 0;
let echecs = 0;

let curseur = 0;
const ouvrier = async (): Promise<void> => {
  for (;;) {
    const i = curseur++;
    if (i >= lignes.length) return;
    const bilan = await convertir(lignes[i]!);
    faits++;
    if (bilan) {
      avant += bilan.avant;
      apres += bilan.apres;
    } else {
      echecs++;
    }
    if (faits % 100 === 0 || faits === lignes.length) {
      const reste = Math.round(((Date.now() - debut) / faits) * (lignes.length - faits) / 60000);
      console.log(`  ${faits}/${lignes.length}  ${mo(avant)} → ${mo(apres)}  reste ~${reste} min`);
    }
  }
};

await Promise.all(Array.from({ length: PARALLELE }, ouvrier));

const gain = avant > 0 ? Math.round((1 - apres / avant) * 100) : 0;
console.log(
  `\n  Terminé : ${faits - echecs} converties, ${echecs} en échec, ` +
    `${Math.round((Date.now() - debut) / 60000)} min.`,
);
console.log(`  ${mo(avant)} → ${mo(apres)}   soit ${gain} % de moins.`);
if (essai) console.log('  (essai : aucune image ni URL modifiée)');
process.exit(0);
