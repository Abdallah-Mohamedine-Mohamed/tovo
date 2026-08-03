import { mkdir, writeFile, access } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { parseDump, type Row } from './dumpParser.js';

/**
 * Récupération des images de l'ancienne app.
 *
 * 6ammart répartit ses fichiers entre deux emplacements, indiqués par la
 * table `storages` : `s3` pour le bucket AWS, `public` pour le disque du
 * serveur. Le dump ne contient que les NOMS ; les fichiers sont ailleurs.
 *
 * Le bucket est en lecture publique — vérifié : une requête sans
 * authentification renvoie bien l'image. On télécharge donc directement,
 * sans clé.
 *
 * Ce qui est sur le disque du serveur n'est joignable que par le domaine de
 * l'ancienne app. Passer `--base https://…` l'active ; sans ce paramètre,
 * ces fichiers sont seulement listés pour qu'on sache ce qui manque.
 *
 *   npx tsx scripts/etl/fetchImages.ts <dump.sql> <destination> [--base URL]
 */

const S3 = 'https://tovoapp.s3.eu-west-3.amazonaws.com';

/**
 * Dossier de rangement selon le type de donnée 6ammart.
 *
 * La photo de couverture d'une boutique fait exception : elle n'est pas
 * rangée avec le logo mais dans un sous-dossier `store/cover`. Chercher les
 * deux au même endroit ramène tous les logos et aucune couverture, sans
 * autre signe qu'une série de 404.
 */
const DOSSIERS: Record<string, string> = {
  Item: 'product',
  Store: 'store',
  StoreCover: 'store/cover',
  Category: 'category',
  User: 'profile',
  UserInfo: 'profile',
  DeliveryMan: 'delivery-man',
};

interface Cible {
  fichier: string;
  dossier: string;
  emplacement: 's3' | 'public';
}

const [, , chemin, destination] = process.argv;
const base = process.argv.includes('--base')
  ? process.argv[process.argv.indexOf('--base') + 1]
  : null;

if (!chemin || !destination) {
  console.error('Usage : tsx scripts/etl/fetchImages.ts <dump.sql> <destination> [--base URL]');
  process.exit(1);
}

const { tables } = await parseDump(
  chemin,
  new Set(['storages', 'items', 'stores', 'categories']),
);

/** Emplacement d'un fichier, d'après la table `storages`. */
const emplacements = new Map<string, 's3' | 'public'>();
for (const s of tables.get('storages') ?? []) {
  const type = (s.data_type ?? '').split('\\').pop() ?? '';
  emplacements.set(`${type}:${s.data_id}`, s.value === 's3' ? 's3' : 'public');
}

const cibles: Cible[] = [];

/**
 * @param type    clé de rangement dans DOSSIERS
 * @param typeSql type tel qu'écrit dans `storages`, qui dit s3 ou serveur —
 *                distinct du précédent car le logo et la couverture d'une
 *                boutique sont deux dossiers mais un seul enregistrement.
 */
const ajouter = (type: string, typeSql: string, id: string | null, fichier: string | null) => {
  if (!fichier || !id) return;
  cibles.push({
    fichier,
    dossier: DOSSIERS[type] ?? 'divers',
    emplacement: emplacements.get(`${typeSql}:${id}`) ?? 'public',
  });
};

for (const i of tables.get('items') ?? []) ajouter('Item', 'Item', i.id, i.image);
for (const s of tables.get('stores') ?? []) {
  ajouter('Store', 'Store', s.id, s.logo);
  ajouter('StoreCover', 'Store', s.id, s.cover_photo);
}
for (const c of tables.get('categories') ?? []) ajouter('Category', 'Category', c.id, c.image);

const surS3 = cibles.filter((c) => c.emplacement === 's3');
const surServeur = cibles.filter((c) => c.emplacement === 'public');

console.log(`${cibles.length} images référencées`);
console.log(`  ${surS3.length} sur S3`);
console.log(`  ${surServeur.length} sur le serveur`);
console.log('');

// ---------------------------------------------------------------------

async function existe(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

async function telecharger(cible: Cible, racine: string): Promise<'ok' | 'absent' | 'erreur' | 'deja'> {
  const sortie = join(destination, racine, cible.dossier, cible.fichier);

  // Reprenable : relancer ne retélécharge pas ce qui est déjà là.
  if (await existe(sortie)) return 'deja';

  const url = `${racine === 's3' ? S3 : base}/${cible.dossier}/${cible.fichier}`;

  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(30000) });
    if (r.status === 404) return 'absent';
    if (!r.ok) return 'erreur';

    await mkdir(dirname(sortie), { recursive: true });
    await writeFile(sortie, Buffer.from(await r.arrayBuffer()));
    return 'ok';
  } catch {
    return 'erreur';
  }
}

/** Télécharge par lots : 12 requêtes en parallèle, pas 2 400 d'un coup. */
async function lot(cibles: Cible[], racine: string, libelle: string): Promise<void> {
  if (cibles.length === 0) return;

  const bilan = { ok: 0, absent: 0, erreur: 0, deja: 0 };
  const TAILLE = 12;

  for (let i = 0; i < cibles.length; i += TAILLE) {
    const tranche = cibles.slice(i, i + TAILLE);
    const resultats = await Promise.all(tranche.map((c) => telecharger(c, racine)));
    for (const r of resultats) bilan[r]++;

    const fait = Math.min(i + TAILLE, cibles.length);
    process.stdout.write(
      `\r${libelle} : ${fait}/${cibles.length}  ` +
        `(${bilan.ok} téléchargées, ${bilan.deja} déjà là, ${bilan.absent} absentes, ${bilan.erreur} erreurs)`,
    );
  }
  console.log('');
}

await lot(surS3, 's3', 'S3      ');

if (base) {
  await lot(surServeur, 'serveur', 'Serveur ');
} else {
  console.log(
    `Serveur : ${surServeur.length} images non récupérées — relancez avec --base https://domaine-de-lancienne-app`,
  );
}
