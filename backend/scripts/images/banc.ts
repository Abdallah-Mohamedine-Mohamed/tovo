/**
 * Banc de recherche par photo, sur de VRAIES photos prises au téléphone
 * (scripts/images/photos/, voir LISEZ-MOI.txt).
 *
 *   npm run images:banc
 *
 * Pour chaque photo : le produit attendu (nom du fichier) est-il dans les
 * résultats ? En tête ? Et combien de temps prend chaque étape — lecture de
 * la photo par Gemini, empreinte visuelle, recherche. Une photo « absent - »
 * ne doit RIEN trouver de ressemblant avec assurance.
 *
 * Même fonction que le serveur (chercherParPhoto). Lecture seule.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { chercherParPhoto } from '../../src/ai/tools.js';
import { normaliserIntention } from '../../src/ai/intents.js';

const DOSSIER = 'scripts/images/photos';
const MIMES: Record<string, string> = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp' };
const photos = readdirSync(DOSSIER).filter((f) => MIMES[extname(f).toLowerCase()]);
if (photos.length === 0) {
  console.log(`Aucune photo dans ${DOSSIER}. Voir LISEZ-MOI.txt.`);
  process.exit(0);
}

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

/** « coca-cola 33 cl 2.jpg » → « coca cola 33 cl » (numéro final retiré). */
const attendu = (fichier: string) => normaliserIntention(fichier.replace(extname(fichier), '').replace(/\s+\d+$/, ''));

let enTete = 0, trouves = 0, absentsOk = 0, absents = 0;
const durees: number[] = [];
for (const fichier of photos) {
  const cible = attendu(fichier);
  const absent = cible.startsWith('absent');
  const debut = performance.now();
  const { resultat, etapes } = await chercherParPhoto(
    readFileSync(join(DOSSIER, fichier)), MIMES[extname(fichier).toLowerCase()]!, '', { db, userId: 'banc' } as never,
  );
  const total = Math.round(performance.now() - debut);
  durees.push(total);
  const noms = (resultat.components[0]?.data.items as Array<{ name: string }> | undefined ?? []).map((i) => normaliserIntention(i.name));
  const rang = noms.findIndex((n) => n === cible || n.includes(cible) || cible.includes(n));
  const lu = (resultat.summary as { lu_sur_la_photo?: string }).lu_sur_la_photo ?? '';

  let verdict: string;
  if (absent) {
    absents++;
    const ok = noms.length === 0;
    if (ok) absentsOk++;
    verdict = ok ? '✓ rien trouvé (attendu)' : `✗ a proposé ${noms.length} produit(s)`;
  } else {
    if (rang === 0) enTete++;
    if (rang >= 0) trouves++;
    verdict = rang === 0 ? '✓ en tête' : rang > 0 ? `~ rang ${rang + 1}` : '✗ absent des résultats';
  }
  console.log(`${verdict.padEnd(26)} ${fichier}  [${etapes.voie}, lu : « ${lu} »]`);
  console.log(`${' '.repeat(27)}vision ${etapes.vision_ms} ms · empreinte ${etapes.empreinte_ms} ms · recherche ${etapes.recherche_ms} ms · total ${total} ms`);
}

const n = photos.length - absents;
const pct = (a: number, b: number) => (b ? `${Math.round((100 * a) / b)} %` : '—');
durees.sort((a, b) => a - b);
console.log(`\n${n} photos de produits : en tête ${pct(enTete, n)}, trouvés ${pct(trouves, n)}.`);
if (absents) console.log(`${absents} photos de produits absents : rien d'inventé dans ${pct(absentsOk, absents)}.`);
console.log(`Durée : médiane ${durees[Math.floor(durees.length / 2)]} ms, max ${durees.at(-1)} ms.`);
