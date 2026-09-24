/**
 * Le direct d'OpenAI (gpt-live-transcribe) sur les vraies notes.
 *
 *   npx tsx --env-file=.env scripts/voix/banc-openai-direct.ts <dossier> [--une]
 *
 * Ce modèle ne passe pas par l'envoi de fichier : c'est une session Realtime
 * (WebSocket). Comme en production, le serveur demande d'abord un jeton
 * temporaire (client secret) : la clé ne quitterait jamais le serveur.
 * Le son part au rythme de la parole, en PCM 24 kHz (format de l'API).
 *
 * Juste après un rechargement de crédit, le compte était limité à 1 session
 * par minute sur ce modèle (500 ensuite). PAUSE_MS règle l'attente entre
 * deux notes (61 s par défaut, par prudence).
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const CLE = process.env.OPENAI_API_KEY!;
const MODELE = process.env.OPENAI_DIRECT ?? 'gpt-live-transcribe';
const AMORCE =
  "Client de Tovo, application de livraison à Niamey (Niger), qui commande en français, parfois en haoussa. " +
  "Noms possibles : O'Takoss, Garba d'Or, bissap, Yantala, attiéké, doukounou, Harobanda, Talladjé, dégué, kilichi, fura.";

function pcm16k(fichier: string): Int16Array {
  const b = readFileSync(fichier);
  let i = 12;
  while (i < b.length - 8) {
    const taille = b.readUInt32LE(i + 4);
    if (b.toString('ascii', i, i + 4) === 'data') {
      const d = b.subarray(i + 8, i + 8 + taille);
      return new Int16Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.length));
    }
    i += 8 + taille + (taille % 2);
  }
  throw new Error('pas de données');
}

/** 16 kHz → 24 kHz, interpolation linéaire. */
function vers24k(e: Int16Array): Buffer {
  const n = Math.floor((e.length * 3) / 2);
  const s = new Int16Array(n);
  for (let i = 0; i < n; i++) {
    const x = (i * 2) / 3;
    const a = Math.floor(x);
    const b = Math.min(a + 1, e.length - 1);
    s[i] = Math.round(e[a]! + (e[b]! - e[a]!) * (x - a));
  }
  return Buffer.from(s.buffer);
}

const session = {
  type: 'transcription',
  audio: {
    input: {
      format: { type: 'audio/pcm', rate: 24000 },
      transcription: { model: MODELE, prompt: AMORCE },
      // Pas de découpage automatique : le client lâche le micro, on valide.
      turn_detection: null,
    },
  },
};

async function jeton(): Promise<string> {
  const r = await fetch('https://api.openai.com/v1/realtime/client_secrets', {
    method: 'POST',
    headers: { authorization: `Bearer ${CLE}`, 'content-type': 'application/json' },
    body: JSON.stringify({ session }),
  });
  const j = (await r.json()) as { value?: string; error?: { message?: string } };
  if (!j.value) throw new Error(`jeton : ${r.status} ${j.error?.message ?? JSON.stringify(j).slice(0, 200)}`);
  return j.value;
}

async function transcrire(son: Buffer, bavard: boolean): Promise<{ texte: string; attente: number; miseEnRoute: number }> {
  const t0 = performance.now();
  const secret = await jeton();
  const ws = new WebSocket('wss://api.openai.com/v1/realtime', ['realtime', `openai-insecure-api-key.${secret}`]);
  return new Promise((ok, ko) => {
    let finParole = 0;
    let miseEnRoute = 0;
    const morceaux: string[] = [];
    const garde = setTimeout(() => { ws.close(); ko(new Error('délai dépassé')); }, 40_000);
    const finir = (texte: string) => {
      clearTimeout(garde);
      ws.close();
      ok({ texte, attente: Math.round(performance.now() - finParole), miseEnRoute: Math.round(miseEnRoute) });
    };
    ws.onerror = () => ko(new Error('WebSocket en erreur'));
    ws.onclose = (e) => { if (!finParole) ko(new Error(`fermée ${e.code} ${e.reason}`)); };
    ws.onmessage = async (e) => {
      const m = JSON.parse(typeof e.data === 'string' ? e.data : await (e.data as Blob).text()) as {
        type: string; delta?: string; transcript?: string; error?: { message?: string };
      };
      if (bavard && !m.type.endsWith('.delta')) console.log(`    · ${m.type}`);
      if (m.type === 'error') { clearTimeout(garde); ko(new Error(m.error?.message ?? 'erreur')); return; }
      if ((m.type === 'session.created' || m.type === 'transcription_session.created') && !finParole && !miseEnRoute) {
        miseEnRoute = performance.now() - t0;
        const MORCEAU = 4800; // 100 ms à 24 kHz, 16 bits
        for (let i = 0; i < son.length; i += MORCEAU) {
          ws.send(JSON.stringify({ type: 'input_audio_buffer.append', audio: son.subarray(i, i + MORCEAU).toString('base64') }));
          await new Promise((r) => setTimeout(r, 100));
        }
        finParole = performance.now();
        ws.send(JSON.stringify({ type: 'input_audio_buffer.commit' }));
        return;
      }
      if (m.type.endsWith('input_audio_transcription.delta') && m.delta) morceaux.push(m.delta);
      if (m.type.endsWith('input_audio_transcription.completed')) finir((m.transcript ?? morceaux.join('')).trim());
    };
  });
}

const dossier = process.argv[2]!;
const une = process.argv.includes('--une');
const fichiers = readdirSync(dossier).filter((f) => f.endsWith('.wav')).sort();
const attentes: number[] = [];
for (const [n, f] of (une ? fichiers.slice(0, 1) : fichiers).entries()) {
  if (n > 0) await new Promise((r) => setTimeout(r, Number(process.env.PAUSE_MS ?? 61_000)));
  try {
    const m = await transcrire(vers24k(pcm16k(join(dossier, f))), une);
    attentes.push(m.attente);
    console.log(`${f}  ${String(m.attente).padStart(5)} ms (mise en route ${m.miseEnRoute} ms)  « ${m.texte} »`);
  } catch (cause) {
    console.log(`${f}  ÉCHEC ${(cause as Error).message.slice(0, 200)}`);
  }
}
attentes.sort((a, b) => a - b);
if (attentes.length) console.log(`\nattente médiane après la note : ${attentes[Math.floor(attentes.length / 2)]} ms`);
process.exit(0);
