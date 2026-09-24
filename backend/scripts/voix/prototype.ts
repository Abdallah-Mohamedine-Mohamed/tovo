/**
 * Prototype de la voix en direct : jeton temporaire + Gemini Live
 * (gemini-3.5-transcribe-live), son envoyé AU RYTHME DE LA PAROLE.
 *
 *   npx tsx --env-file=.env scripts/voix/prototype.ts <fichier.wav 16 kHz mono>
 *
 * Mesure : quand arrivent les premiers mots, et combien de temps après la
 * fin de la phrase le texte final est prêt — l'attente réelle du client.
 */
import { readFileSync } from 'node:fs';

const CLE = process.env.GEMINI_API_KEY!;
const MODELE = 'models/gemini-3.5-transcribe-live';
const fichier = process.argv[2]!;
const VOCABULAIRE = ["O'Takoss", 'bissap', 'Yantala', 'attiéké', 'doukounou', 'Tovo'];

// 1. Jeton temporaire, comme le fera le serveur.
const expire = new Date(Date.now() + 2 * 60_000).toISOString();
const t0 = performance.now();
const reponseJeton = await fetch('https://generativelanguage.googleapis.com/v1alpha/auth_tokens', {
  method: 'POST',
  headers: { 'x-goog-api-key': CLE, 'content-type': 'application/json' },
  body: JSON.stringify({
    uses: 1,
    expireTime: expire,
    newSessionExpireTime: expire,
    bidiGenerateContentSetup: { model: MODELE, generationConfig: { responseModalities: ['TEXT'] }, inputAudioTranscription: { languageCodes: ['fr-FR', 'ha-NG'], customVocabulary: VOCABULAIRE, mode: 'SMART' } },
  }),
});
const corpsJeton = (await reponseJeton.json()) as { name?: string; error?: { message?: string } };
console.log(`jeton : ${reponseJeton.status} en ${Math.round(performance.now() - t0)} ms ${corpsJeton.error?.message ?? ''}`);
const jeton = corpsJeton.name;

// 2. Connexion directe à Gemini, avec le jeton (pas la clé).
const url = jeton
  ? `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=${encodeURIComponent(jeton)}`
  : `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${CLE}`;
console.log(jeton ? 'connexion avec le jeton temporaire' : '⚠ pas de jeton : connexion avec la clé (test seulement)');

const wav = readFileSync(fichier);
const pcm = wav.subarray(44); // en-tête WAV standard
const MORCEAU = 3200; // 100 ms à 16 kHz, 16 bits, mono

const debutConnexion = performance.now();
const ws = new WebSocket(url);
let finParole = 0;
let premierMot = 0;
let finalRecu = false;

ws.onopen = async () => {
  console.log(`connecté en ${Math.round(performance.now() - debutConnexion)} ms`);
  ws.send(JSON.stringify({
    setup: {
      model: MODELE,
      generationConfig: { responseModalities: ['TEXT'] },
      inputAudioTranscription: { languageCodes: ['fr-FR', 'ha-NG'], customVocabulary: VOCABULAIRE, mode: 'SMART' },
    },
  }));
};

ws.onmessage = async (evenement) => {
  const texte = typeof evenement.data === 'string' ? evenement.data : await (evenement.data as Blob).text();
  const m = JSON.parse(texte) as {
    setupComplete?: unknown;
    serverContent?: { interimInputTranscription?: { text?: string }; inputTranscription?: { text?: string } };
    error?: unknown;
  };
  if (m.setupComplete !== undefined) {
    console.log('prêt — envoi du son au rythme de la parole…');
    const debutSon = performance.now();
    for (let i = 0; i < pcm.length; i += MORCEAU) {
      ws.send(JSON.stringify({ realtimeInput: { audio: { data: pcm.subarray(i, i + MORCEAU).toString('base64'), mimeType: 'audio/pcm;rate=16000' } } }));
      await new Promise((r) => setTimeout(r, 100));
    }
    finParole = performance.now();
    console.log(`fin de la phrase après ${Math.round(finParole - debutSon)} ms de parole`);
    ws.send(JSON.stringify({ realtimeInput: { audioStreamEnd: true } }));
    return;
  }
  const interim = m.serverContent?.interimInputTranscription?.text;
  if (interim) {
    if (!premierMot) premierMot = performance.now();
    console.log(`   … « ${interim} »`);
  }
  const final = m.serverContent?.inputTranscription?.text;
  if (final) {
    const attente = finParole ? Math.round(performance.now() - finParole) : NaN;
    console.log(`FINAL : « ${final} » — prêt ${attente} ms après la fin de la phrase`);
    finalRecu = true;
  }
  if (m.error) console.log('erreur :', JSON.stringify(m.error));
};
ws.onerror = (e) => console.log('erreur WebSocket :', (e as { message?: string }).message ?? e);
ws.onclose = (e) => { console.log(`fermé (${e.code}) ${e.reason}`); process.exit(finalRecu ? 0 : 1); };
setTimeout(() => { console.log('délai dépassé'); ws.close(); }, 40_000);
