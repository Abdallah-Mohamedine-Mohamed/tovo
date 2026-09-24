import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import ffmpeg from 'ffmpeg-static';

/**
 * AAC du téléphone → WAV 16 kHz mono, pour MAI-Transcribe.
 *
 * MAI n'accepte que WAV, MP3 ou FLAC. Le téléphone, lui, doit envoyer de
 * l'AAC : dix secondes pèsent ~40 Ko contre ~320 Ko en WAV, et sur le
 * réseau nigérien c'est l'envoi qui coûte. La conversion se fait donc ICI,
 * en quelques dizaines de millisecondes, et le WAV repart du centre de
 * données, où son poids ne coûte rien.
 *
 * Par un fichier temporaire et non par un tuyau : dans un m4a enregistré par
 * un téléphone, l'index du fichier est souvent À LA FIN, et ffmpeg ne peut
 * pas revenir en arrière dans un flux.
 */
export async function enWav(audio: { mime: string; data: string }): Promise<{ mime: 'audio/wav'; data: string }> {
  if (audio.mime === 'audio/wav') return { mime: 'audio/wav', data: audio.data };
  if (!ffmpeg) throw new Error('ffmpeg indisponible sur cette machine');

  const source = join(tmpdir(), `tovo-voix-${randomUUID()}`);
  await writeFile(source, Buffer.from(audio.data, 'base64'));
  try {
    const wav = await new Promise<Buffer>((ok, ko) => {
      const processus = spawn(
        ffmpeg!,
        ['-hide_banner', '-loglevel', 'error', '-i', source, '-ac', '1', '-ar', '16000', '-f', 'wav', 'pipe:1'],
        { timeout: 5_000 },
      );
      const morceaux: Buffer[] = [];
      let erreur = '';
      processus.stdout.on('data', (m: Buffer) => morceaux.push(m));
      processus.stderr.on('data', (m: Buffer) => { erreur += m.toString(); });
      processus.on('error', ko);
      processus.on('close', (code) =>
        code === 0 ? ok(Buffer.concat(morceaux)) : ko(new Error(`conversion impossible (${code}) : ${erreur.slice(0, 200)}`)),
      );
    });
    return { mime: 'audio/wav', data: wav.toString('base64') };
  } finally {
    // La voix d'un client n'a rien à faire sur le disque du serveur.
    await rm(source, { force: true });
  }
}
