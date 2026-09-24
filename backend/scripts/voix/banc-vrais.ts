/**
 * Les deux fournisseurs sur de VRAIES notes vocales (WAV 16 kHz mono).
 *
 *   npx tsx --env-file=.env scripts/voix/banc-vrais.ts <dossier>
 *
 * Pas de texte de référence : les deux transcriptions sont affichées côte à
 * côte, avec l'attente après la fin de la note. Les notes restent hors du
 * dépôt : ce sont des voix de personnes réelles.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

process.argv.push('--module');
const { gemini, eleven } = await import('./banc-stt.js');

/** Les données PCM, quel que soit l'en-tête (ffmpeg peut ajouter un LIST). */
function pcm(fichier: string): Buffer {
  const b = readFileSync(fichier);
  let i = 12;
  while (i < b.length - 8) {
    const id = b.toString('ascii', i, i + 4);
    const taille = b.readUInt32LE(i + 4);
    if (id === 'data') return b.subarray(i + 8, i + 8 + taille);
    i += 8 + taille + (taille % 2);
  }
  throw new Error(`pas de données audio dans ${fichier}`);
}

const dossier = process.argv[2]!;
const attentes: Record<string, number[]> = { Gemini: [], ElevenLabs: [] };
for (const [n, f] of readdirSync(dossier).filter((x) => x.endsWith('.wav')).sort().entries()) {
  const son = pcm(join(dossier, f));
  console.log(`\n— ${f} (${(son.length / 32000).toFixed(1)} s)`);
  // Ordre alterné d'une note à l'autre : aucun des deux n'a toujours la
  // connexion « chaude ».
  const ordre = n % 2 ? ([['ElevenLabs', eleven], ['Gemini', gemini]] as const) : ([['Gemini', gemini], ['ElevenLabs', eleven]] as const);
  for (const [nom, fn] of ordre) {
    try {
      const m = await fn(son);
      attentes[nom]!.push(m.attenteMs);
      console.log(`  ${nom.padEnd(10)} ${String(m.attenteMs).padStart(5)} ms  « ${m.texte} »`);
    } catch (cause) {
      console.log(`  ${nom.padEnd(10)} ÉCHEC ${(cause as Error).message.slice(0, 140)}`);
    }
  }
}
const med = (v: number[]) => [...v].filter(Number.isFinite).sort((a, b) => a - b)[Math.floor(v.length / 2)];
console.log(`\nattente médiane après la note — Gemini ${med(attentes.Gemini!)} ms · ElevenLabs ${med(attentes.ElevenLabs!)} ms`);
process.exit(0);
