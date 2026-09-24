/**
 * Un message avec une pause au milieu : les deux fournisseurs rendent-ils
 * TOUT le message ?
 *
 *   npx tsx --env-file=.env scripts/voix/banc-pause.ts
 *
 * Pendant la mise au point du banc, Gemini Live a rendu la seconde phrase
 * d'un son qui en contenait deux, sans la première. Un client qui dit
 * « Je veux un livreur. … C'est pour Harobanda. » ne doit rien perdre.
 * On assemble deux sons du banc avec 0,6 s, 1,2 s puis 2 s de silence.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DOSSIER = join(import.meta.dirname, 'sons');
const fichiers = readdirSync(DOSSIER).filter((f) => f.endsWith('-propre.wav')).sort();
if (fichiers.length < 4) throw new Error('lancez d\'abord banc-stt.ts pour fabriquer les sons');

const pcm = (f: string) => readFileSync(join(DOSSIER, f)).subarray(44);
const silence = (s: number) => Buffer.alloc(Math.round(s * 16000) * 2);

process.argv.push('--module');
const { gemini, eleven } = await import('./banc-stt.js');

const paires: [string, string][] = [
  [fichiers[2]!, fichiers[3]!],
  [fichiers[0]!, fichiers[14]!],
];
for (const [a, b] of paires) {
  for (const pause of [0.6, 1.2, 2]) {
    const son = Buffer.concat([pcm(a), silence(pause), pcm(b)]);
    for (const [nom, fn] of [['Gemini', gemini], ['ElevenLabs', eleven]] as const) {
      try {
        const m = await fn(son);
        console.log(`${nom.padEnd(11)} pause ${pause} s · ${m.attenteMs} ms · « ${m.texte} »`);
      } catch (cause) {
        console.log(`${nom.padEnd(11)} pause ${pause} s · ÉCHEC ${(cause as Error).message.slice(0, 120)}`);
      }
    }
  }
}
process.exit(0);
