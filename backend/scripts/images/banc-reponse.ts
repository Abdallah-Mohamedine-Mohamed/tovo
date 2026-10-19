/**
 * Banc de la RÉPONSE à une photo (19/10) : ce que le client lit — la phrase
 * et le titre des résultats — et pas seulement les produits trouvés.
 *
 *   npx tsx --env-file=.env scripts/images/banc-reponse.ts
 *
 * Photos dans scripts/images/photos-reponse/ : « absent - … » = produit que
 * Tovo ne vend pas (la réponse ne doit PAS dire l'avoir trouvé) ; les autres
 * = produit vendu. Même chemin que le serveur (chercherParPhoto, puis la
 * rédaction du chat). Lecture seule. ~4 appels Gemini Flash-Lite par photo.
 * On RELIT chaque réponse : le banc affiche, il ne note pas.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { chercherParPhoto } from '../../src/ai/tools.js';
import * as redacteur from '../../src/ai/redacteur.js';

const DOSSIER = 'scripts/images/photos-reponse';
const MIMES: Record<string, string> = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png' };
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const rediger = (redacteur as Record<string, unknown>).redigerReponsePhoto as
  | ((r: { indication: string; resultat: Awaited<ReturnType<typeof chercherParPhoto>>['resultat'] }) => Promise<string>)
  | undefined;
console.log(rediger ? 'Chemin : APRÈS (rédacteur)\n' : 'Chemin : AVANT (phrase du code)\n');

for (const fichier of readdirSync(DOSSIER).filter((f) => MIMES[extname(f).toLowerCase()])) {
  const { resultat } = await chercherParPhoto(readFileSync(join(DOSSIER, fichier)), MIMES[extname(fichier).toLowerCase()]!, '', { db, userId: 'banc' } as never);
  const phrase = rediger ? await rediger({ indication: '', resultat }) : resultat.content ?? '';
  const carte = resultat.components[0]?.data as { title?: string; items?: Array<{ name: string }> } | undefined;
  const s = resultat.summary as { lu_sur_la_photo?: string };
  console.log(`■ ${fichier}`);
  console.log(`  lu      : ${s.lu_sur_la_photo ?? '—'}`);
  console.log(`  phrase  : ${phrase}`);
  console.log(`  titre   : ${carte?.title ?? '—'}`);
  console.log(`  produits: ${(carte?.items ?? []).slice(0, 4).map((i) => i.name).join(' | ') || '—'}\n`);
}
