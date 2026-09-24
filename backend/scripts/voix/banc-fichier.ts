/**
 * Transcription de la NOTE ENTIÈRE, une fois finie (comme l'appli ChatGPT),
 * contre le direct. Mêmes notes que banc-vrais.ts.
 *
 *   npx tsx --env-file=.env scripts/voix/banc-fichier.ts <dossier de WAV>
 *
 * L'attente mesurée est celle du client : de l'instant où il lâche le micro
 * (l'envoi du fichier commence) au texte reçu. Envoi compris : depuis
 * Niamey, c'est une part réelle de l'attente.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const VOCABULAIRE = [
  "O'Takoss", "Garba d'Or", 'bissap', 'Yantala', 'attiéké', 'doukounou', 'Tovo',
  'Harobanda', 'Talladjé', 'dégué', 'kilichi', 'fura', 'Lina Chips', 'Niamey', 'Plateau',
];
const AMORCE =
  "Client de Tovo, application de livraison à Niamey (Niger), qui commande en français, parfois en haoussa. " +
  `Noms possibles : ${VOCABULAIRE.join(', ')}.`;

type Transcrire = (wav: Buffer) => Promise<string>;

async function openai(modele: string): Promise<Transcrire> {
  return async (wav) => {
    const form = new FormData();
    form.append('file', new Blob([wav], { type: 'audio/wav' }), 'note.wav');
    form.append('model', modele);
    // Pas de langue imposée : le client peut parler haoussa. L'amorce donne
    // le contexte et les noms propres.
    form.append('prompt', AMORCE);
    const r = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
      body: form,
    });
    const j = (await r.json()) as { text?: string; error?: { message?: string } };
    if (!r.ok) throw new Error(j.error?.message ?? String(r.status));
    return j.text ?? '';
  };
}

const elevenFichier: Transcrire = async (wav) => {
  const form = new FormData();
  form.append('file', new Blob([wav], { type: 'audio/wav' }), 'note.wav');
  form.append('model_id', 'scribe_v2');
  form.append('no_verbatim', 'true');
  form.append('tag_audio_events', 'false');
  for (const mot of VOCABULAIRE) form.append('keyterms', mot);
  const r = await fetch('https://api.elevenlabs.io/v1/speech-to-text', {
    method: 'POST',
    headers: { 'xi-api-key': process.env.ELEVENLABS_API_KEY! },
    body: form,
  });
  const j = (await r.json()) as { text?: string; detail?: unknown };
  if (!r.ok) throw new Error(JSON.stringify(j.detail ?? r.status).slice(0, 200));
  return j.text ?? '';
};

const geminiFichier: Transcrire = async (wav) => {
  const r = await fetch(
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent',
    {
      method: 'POST',
      headers: { 'x-goog-api-key': process.env.GEMINI_API_KEY!, 'content-type': 'application/json' },
      body: JSON.stringify({
        contents: [{
          parts: [
            { text: `${AMORCE} Transcris fidèlement, sans traduire ni répondre.` },
            { inlineData: { mimeType: 'audio/wav', data: wav.toString('base64') } },
          ],
        }],
      }),
    },
  );
  const j = (await r.json()) as {
    candidates?: { content?: { parts?: { text?: string; audioTranscription?: { text?: string } }[] } }[];
    error?: { message?: string };
  };
  if (!r.ok) throw new Error(j.error?.message ?? String(r.status));
  // Ce modèle rend le texte dans audioTranscription, pas dans text.
  return (j.candidates?.[0]?.content?.parts ?? [])
    .map((p) => p.audioTranscription?.text ?? p.text ?? '')
    .join('')
    .trim();
};

// ------------------------------------------------------------------------

/**
 * Modèles « qui écoutent » (chat avec entrée audio) : on leur demande une
 * transcription mot pour mot. Même consigne pour tous.
 */
const CONSIGNE_ECOUTE =
  `${AMORCE} Transcris mot pour mot ce que dit cette note vocale, dans sa langue, ` +
  'sans traduire, sans répondre, sans rien ajouter. Réponds uniquement par la transcription.';

function chatAudio(url: string, cle: string, modele: string, extra: Record<string, unknown> = {}): Transcrire {
  return async (wav) => {
    const r = await fetch(url, {
      method: 'POST',
      headers: { authorization: `Bearer ${cle}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        model: modele,
        temperature: 0,
        messages: [{
          role: 'user',
          content: [
            { type: 'text', text: CONSIGNE_ECOUTE },
            { type: 'input_audio', input_audio: { data: wav.toString('base64'), format: 'wav' } },
          ],
        }],
        ...extra,
      }),
    });
    const j = (await r.json()) as { choices?: { message?: { content?: string } }[]; error?: { message?: string } };
    if (!r.ok || j.error) throw new Error(j.error?.message ?? String(r.status));
    return (j.choices?.[0]?.message?.content ?? '').trim();
  };
}

const openrouter = (modele: string) =>
  chatAudio('https://openrouter.ai/api/v1/chat/completions', process.env.OPENROUTER_API_KEY!, modele);

function cloudflare(modele: string, corps: (wav: Buffer) => unknown, lire: (r: unknown) => string): Transcrire {
  return async (wav) => {
    const r = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${process.env.CLOUDFLARE_ACCOUNT_ID}/ai/run/${modele}`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}`, 'content-type': 'application/json' },
        body: JSON.stringify(corps(wav)),
      },
    );
    const j = (await r.json()) as { result?: unknown; errors?: { message?: string }[] };
    if (!r.ok || !j.result) throw new Error(j.errors?.[0]?.message ?? JSON.stringify(j).slice(0, 200));
    return lire(j.result);
  };
}

const geminiEcoute = (modele: string): Transcrire => async (wav) => {
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
    method: 'POST',
    headers: { 'x-goog-api-key': process.env.GEMINI_API_KEY!, 'content-type': 'application/json' },
    body: JSON.stringify({
      contents: [{ parts: [{ text: CONSIGNE_ECOUTE }, { inlineData: { mimeType: 'audio/wav', data: wav.toString('base64') } }] }],
      generationConfig: { temperature: 0, thinkingConfig: { thinkingBudget: 0 } },
    }),
  });
  const j = (await r.json()) as { candidates?: { content?: { parts?: { text?: string }[] } }[]; error?: { message?: string } };
  if (!r.ok) throw new Error(j.error?.message ?? String(r.status));
  return (j.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? '').join('').trim();
};

/**
 * Les modèles de transcription d'OpenRouter ont leur propre route, absente
 * du catalogue des modèles de conversation (d'où « introuvable » au début).
 * Pas de langue imposée : MAI détecte et suit les passages français/haoussa.
 */
const openrouterStt = (modele: string, azure?: Record<string, unknown>): Transcrire => async (wav) => {
  const r = await fetch('https://openrouter.ai/api/v1/audio/transcriptions', {
    method: 'POST',
    headers: { authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      model: modele,
      input_audio: { data: wav.toString('base64'), format: 'wav' },
      temperature: 0,
      // STT_LANGUE=fr : sans elle, la plupart partaient en hindi, arabe ou
      // polonais sur l'accent nigérien.
      ...(process.env.STT_LANGUE ? { language: process.env.STT_LANGUE } : {}),
      ...(azure ? { provider: { options: { azure } } } : {}),
    }),
  });
  const j = (await r.json()) as { text?: string; error?: { message?: string } };
  if (!r.ok || j.error) throw new Error(j.error?.message ?? String(r.status));
  return (j.text ?? '').trim();
};

/** Tous les modèles de transcription d'OpenRouter pas encore couverts ailleurs. */
const AUTRES_OPENROUTER = [
  'x-ai/grok-stt-1.0',
  'meta/muse-voice-transcribe-1.0',
  'qwen/qwen3-asr-flash-2026-02-10',
  'qwen/qwen3-asr-1.7b',
  'qwen/qwen3-asr-0.6b',
  'nvidia/parakeet-tdt-0.6b-v3',
  'nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b',
  'fish-audio/transcribe-1',
  'mistralai/voxtral-mini-transcribe',
  'mistralai/voxtral-small-24b-2507-stt',
  'openai/whisper-large-v3',
];

/**
 * MAI-Transcribe-2 directement chez Microsoft (Azure Speech, transcription
 * rapide), sans OpenRouter. Même liste de mots, même style « propre ».
 */
const azureDirect: Transcrire = async (wav) => {
  const form = new FormData();
  form.append('audio', new Blob([wav], { type: 'audio/wav' }), 'note.wav');
  form.append('definition', JSON.stringify({
    enhancedMode: { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'clean' } },
    phraseList: { phrases: VOCABULAIRE },
  }));
  const r = await fetch(
    `https://${process.env.AZURE_SPEECH_REGION}.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15`,
    { method: 'POST', headers: { 'Ocp-Apim-Subscription-Key': process.env.AZURE_SPEECH_KEY! }, body: form },
  );
  const j = (await r.json()) as { combinedPhrases?: { text?: string }[]; error?: { message?: string }; message?: string };
  if (!r.ok) throw new Error(j.error?.message ?? j.message ?? String(r.status));
  return (j.combinedPhrases ?? []).map((p) => p.text ?? '').join(' ').trim();
};

const tous: [string, () => Transcrire | Promise<Transcrire>][] = [
  ['Azure direct MAI-2 + mots', () => azureDirect],
  ...AUTRES_OPENROUTER.map((id): [string, () => Transcrire] => [`OR ${id}`, () => openrouterStt(id)]),
  ['Microsoft MAI-Transcribe-2', () => openrouterStt('microsoft/mai-transcribe-2')],
  // Avec la liste de mots et le style « propre » (sans « euh » ni bégaiements).
  ['Microsoft MAI-2 + mots', () =>
    openrouterStt('microsoft/mai-transcribe-2', {
      phraseList: { phrases: VOCABULAIRE },
      enhancedMode: { modelOptions: { transcribeStyle: 'clean' } },
    })],
  ['Microsoft MAI-Transcribe-1.5', () => openrouterStt('microsoft/mai-transcribe-1.5')],
  ['OpenAI gpt-transcribe', () => openai('gpt-transcribe')],
  ['OpenAI whisper-1', () => openai('whisper-1')],
  ['OpenAI gpt-audio-1.5', () =>
    chatAudio('https://api.openai.com/v1/chat/completions', process.env.OPENAI_API_KEY!, 'gpt-audio-1.5', { modalities: ['text'] })],
  ['OpenAI gpt-audio-mini', () =>
    chatAudio('https://api.openai.com/v1/chat/completions', process.env.OPENAI_API_KEY!, 'gpt-audio-mini', { modalities: ['text'] })],
  ['Mistral Voxtral Small', () => openrouter('mistralai/voxtral-small-24b-2507')],
  ['Qwen 3.8 Omni Flash', () => openrouter('qwen/qwen3.8-omni-flash')],
  ['Xiaomi MiMo 2.6 Flash', () => openrouter('xiaomi/mimo-v2.6-flash')],
  ['Google Gemini 3.8 Flash', () => geminiEcoute('gemini-3.8-flash')],
  // Deepgram sur Cloudflare veut le son BRUT dans le corps, réglages en
  // paramètres d'URL (le JSON avec base64 est refusé).
  ['Deepgram Nova-3 (Cloudflare)', () => async (wav: Buffer) => {
    const r = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${process.env.CLOUDFLARE_ACCOUNT_ID}/ai/run/@cf/deepgram/nova-3?language=fr&smart_format=true`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}`, 'content-type': 'audio/wav' },
        body: wav,
      },
    );
    const j = (await r.json()) as {
      result?: { results?: { channels?: { alternatives?: { transcript?: string }[] }[] } };
      errors?: { message?: string }[];
    };
    if (!r.ok) throw new Error(j.errors?.[0]?.message ?? String(r.status));
    return j.result?.results?.channels?.[0]?.alternatives?.[0]?.transcript ?? '';
  }],
  ['Whisper large v3 turbo (Cloudflare)', () =>
    cloudflare(
      '@cf/openai/whisper-large-v3-turbo',
      (wav) => ({ audio: wav.toString('base64'), language: 'fr', initial_prompt: AMORCE }),
      (r) => ((r as { text?: string }).text ?? ''),
    )],
  ['ElevenLabs Scribe v2', () => elevenFichier],
  ['Gemini 3.5 Transcribe', () => geminiFichier],
];

// SEULS="voxtral,nova" : seulement les fournisseurs dont le nom contient l'un
// de ces mots.
const seuls = (process.env.SEULS ?? '').toLowerCase().split(',').filter(Boolean);
const fournisseurs: [string, Transcrire][] = [];
for (const [nom, fabriquer] of tous) {
  if (seuls.length && !seuls.some((s) => nom.toLowerCase().includes(s))) continue;
  fournisseurs.push([nom, await fabriquer()]);
}
console.log(`fournisseurs : ${fournisseurs.map(([n]) => n).join(' · ')}`);

const dossier = process.argv[2]!;
const attentes = new Map<string, number[]>(fournisseurs.map(([n]) => [n, []]));
const horsJeu = new Set<string>();
for (const f of readdirSync(dossier).filter((x) => x.endsWith('.wav')).sort()) {
  const wav = readFileSync(join(dossier, f));
  console.log(`\n— ${f}`);
  // Gemini transcribe : 10 requêtes par minute sur ce compte.
  await new Promise((ok) => setTimeout(ok, 6500));
  for (const [nom, fn] of fournisseurs) {
    if (horsJeu.has(nom)) continue;
    const t0 = performance.now();
    try {
      const texte = await fn(wav);
      const ms = Math.round(performance.now() - t0);
      attentes.get(nom)!.push(ms);
      console.log(`  ${nom.padEnd(34)} ${String(ms).padStart(5)} ms  « ${texte.trim()} »`);
    } catch (cause) {
      console.log(`  ${nom.padEnd(34)} ÉCHEC ${(cause as Error).message.slice(0, 160)}`);
      // Plus de crédit ou clé refusée : inutile d'insister sur les autres notes.
      if (/credits|quota|api key/i.test((cause as Error).message)) horsJeu.add(nom);
    }
  }
}
console.log('\nattente médiane après la note :');
for (const [nom, v] of attentes) {
  const t = [...v].sort((a, b) => a - b);
  if (!t.length) {
    console.log(`  ${nom.padEnd(34)} aucune mesure`);
    continue;
  }
  console.log(`  ${nom.padEnd(34)} médiane ${t[Math.floor(t.length / 2)]} ms · pire ${t.at(-1)} ms`);
}
process.exit(0);
