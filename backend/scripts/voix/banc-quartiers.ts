/**
 * La liste de mots de la transcription, AVANT et APRÈS l'ajout des quartiers
 * de Niamey (09/10 : « Bobiel » transcrit « BOBA »), sur de vraies notes.
 *
 *   npx tsx --env-file=.env scripts/voix/banc-quartiers.ts <dossier> [note-en-plus.m4a …]
 *
 * Le même fournisseur que l'application (transcrire : MAI-Transcribe-2, puis
 * ses secours), seule la liste change. Les deux textes sont affichés côte à
 * côte : c'est à RELIRE, il n'y a pas de texte de référence. Les notes
 * restent hors du dépôt : ce sont des voix de personnes réelles.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { transcrire } from '../../src/services/transcription.js';
import { vocabulaire } from '../../src/services/voixDirecte.js';

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
const [dossier, ...enPlus] = process.argv.slice(2);
if (!dossier) throw new Error('usage : banc-quartiers.ts <dossier> [notes…]');
const MIME: Record<string, string> = { '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.aac': 'audio/aac' };
const notes = [
  ...readdirSync(dossier).filter((f) => MIME[extname(f).toLowerCase()]).map((f) => join(dossier, f)),
  ...enPlus,
];

const avant = await vocabulaire(db, { avecQuartiers: false });
const apres = await vocabulaire(db);
console.log(`liste : ${avant.length} mots avant, ${apres.length} après\n`);
let differences = 0;
for (const note of notes) {
  const audio = { mime: MIME[extname(note).toLowerCase()]!, data: readFileSync(note).toString('base64') };
  // L'une après l'autre (pas de 429), et une panne n'arrête pas le banc.
  const essai = async (mots: string[]) => {
    try { return await transcrire(audio, mots); } catch (e) { return { texte: `[ÉCHEC ${(e as Error).message.slice(0, 80)}]`, fournisseur: '—' }; }
  };
  const a = await essai(avant);
  const b = await essai(apres);
  const pareil = a.texte.trim() === b.texte.trim();
  if (!pareil) differences++;
  console.log(`— ${note.split(/[\\/]/).pop()}${pareil ? ' (identique)' : ''}`);
  console.log(`   avant : ${a.texte}  [${a.fournisseur}]`);
  if (!pareil) console.log(`   après : ${b.texte}  [${b.fournisseur}]`);
}
console.log(`\n${differences} note(s) sur ${notes.length} transcrites différemment.`);
