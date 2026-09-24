/**
 * Banc comparatif de la voix en direct : Gemini Live contre ElevenLabs
 * Scribe v2 Realtime, sur EXACTEMENT les mêmes sons.
 *
 *   npx tsx --env-file=.env scripts/voix/banc-stt.ts            (tout)
 *   npx tsx --env-file=.env scripts/voix/banc-stt.ts --gemini   (un seul)
 *   npx tsx --env-file=.env scripts/voix/banc-stt.ts --eleven
 *
 * Les sons sont fabriqués par la synthèse vocale de Google — un tiers : faire
 * parler ElevenLabs pour tester ElevenLabs l'avantagerait. Chaque phrase est
 * dite par plusieurs voix, avec consigne d'accent d'Afrique de l'Ouest, puis
 * existe en deux versions : propre, et avec un bruit de rue (≈ 12 dB).
 * Générés une fois, gardés dans scripts/voix/sons/.
 *
 * Le son est envoyé AU RYTHME DE LA PAROLE (100 ms toutes les 100 ms), comme
 * le téléphone. On mesure ce que vit le client : le temps entre la fin de sa
 * phrase et le texte final, puis la justesse — surtout des mots locaux.
 *
 * Limite honnête : une voix de synthèse n'est pas un vrai client de Niamey.
 * Le banc départage les deux fournisseurs dans les mêmes conditions ; il ne
 * prédit pas le taux d'erreur réel.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const DOSSIER = join(import.meta.dirname, 'sons');
const CLE_GOOGLE = process.env.GEMINI_API_KEY!;
const CLE_ELEVEN = process.env.ELEVENLABS_API_KEY;
const MODELE_TTS = 'gemini-3.8-flash-tts';
const MODELE_LIVE = 'models/gemini-3.5-transcribe-live';
const FREQ = 16000;
const MORCEAU = 3200; // 100 ms, 16 bits mono

/** Même vocabulaire pour les deux : ce que l'app enverrait. */
const VOCABULAIRE = [
  "O'Takoss", 'Garba d\'Or', 'bissap', 'Yantala', 'attiéké', 'doukounou', 'Tovo',
  'Harobanda', 'Talladjé', 'dégué', 'kilichi', 'fura', 'Lina Chips', 'Niamey', 'Plateau',
];

interface Phrase {
  texte: string;
  /** Les mots qui DOIVENT être justes pour que la commande parte bien. */
  cles: string[];
}

const PHRASES: Phrase[] = [
  { texte: 'Je veux un doukounou chez Garba d\'Or', cles: ['doukounou', 'garba'] },
  { texte: 'Un attiéké poisson, s\'il vous plaît', cles: ['attieke', 'poisson'] },
  { texte: 'Je veux un livreur à Yantala', cles: ['livreur', 'yantala'] },
  { texte: 'Envoie un colis à Harobanda, près du marché', cles: ['colis', 'harobanda'] },
  { texte: 'Deux tacos XL chez O\'Takoss', cles: ['tacos', 'takoss'] },
  { texte: 'Est-ce que vous avez du bissap bien frais ?', cles: ['bissap'] },
  { texte: 'Donne-moi du kilichi et une bouteille de dégué', cles: ['kilichi', 'degue'] },
  { texte: 'Je veux du poulet braisé avec des frites', cles: ['poulet', 'braise'] },
  { texte: 'Comme d\'habitude', cles: ['habitude'] },
  { texte: 'Le deuxième, celui à deux mille', cles: ['deuxieme', '2000|deux mille'] },
  { texte: 'Une pizza reine et un jus de gingembre', cles: ['pizza', 'gingembre'] },
  { texte: 'Il me faut une recharge de gaz de six kilos', cles: ['gaz', '6|six'] },
  { texte: 'Où en est ma commande ?', cles: ['commande'] },
  { texte: 'Annule ma commande', cles: ['annule'] },
  { texte: 'Je suis à Talladjé, derrière la pharmacie', cles: ['talladje', 'pharmacie'] },
  { texte: 'Des chips Lina Chips et une boisson', cles: ['lina', 'chips'] },
  { texte: 'Je voudrais du riz sauce arachide', cles: ['riz', 'arachide'] },
  { texte: 'Montre-moi les restaurants ouverts au Plateau', cles: ['restaurants', 'plateau'] },
  { texte: 'Un fura avec du lait, bien sucré', cles: ['fura', 'lait'] },
  { texte: 'Appelle le livreur, je ne le vois pas', cles: ['livreur'] },
];

/** Plusieurs voix : une seule serait un banc sur une seule gorge. */
const VOIX = ['Kore', 'Puck', 'Charon'];
/** Aucune consigne : toute consigne (français, anglais) était LUE à voix haute
 * avec la phrase, et ce modèle refuse les instructions système. Pas d'accent
 * imposé, donc : c'est la principale limite du banc. */
const CONSIGNE = '';

// ---------------------------------------------------------------- sons ----

function wav(pcm: Buffer): Buffer {
  const e = Buffer.alloc(44);
  e.write('RIFF', 0); e.writeUInt32LE(36 + pcm.length, 4); e.write('WAVE', 8);
  e.write('fmt ', 12); e.writeUInt32LE(16, 16); e.writeUInt16LE(1, 20); e.writeUInt16LE(1, 22);
  e.writeUInt32LE(FREQ, 24); e.writeUInt32LE(FREQ * 2, 28); e.writeUInt16LE(2, 32); e.writeUInt16LE(16, 34);
  e.write('data', 36); e.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([e, pcm]);
}

/** 24 kHz → 16 kHz, interpolation linéaire : largement assez pour la parole. */
function reechantillonner(pcm: Buffer, source: number): Int16Array {
  const entree = new Int16Array(pcm.buffer, pcm.byteOffset, pcm.length / 2);
  const n = Math.floor((entree.length * FREQ) / source);
  const sortie = new Int16Array(n);
  for (let i = 0; i < n; i++) {
    const x = (i * source) / FREQ;
    const a = Math.floor(x);
    const b = Math.min(a + 1, entree.length - 1);
    sortie[i] = Math.round(entree[a]! + (entree[b]! - entree[a]!) * (x - a));
  }
  return sortie;
}

/** Bruit de rue : bruit rose + ronflement de moteur, ≈ 12 dB sous la voix. */
function bruiter(voix: Int16Array, graine: number): Int16Array {
  let s = graine;
  const alea = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff) * 2 - 1;
  const rms = Math.sqrt(voix.reduce((t, v) => t + v * v, 0) / voix.length);
  const cible = rms / Math.pow(10, 12 / 20);
  let b0 = 0, b1 = 0, b2 = 0;
  const bruit = new Float64Array(voix.length);
  for (let i = 0; i < voix.length; i++) {
    const w = alea();
    b0 = 0.99765 * b0 + w * 0.099; b1 = 0.963 * b1 + w * 0.2965; b2 = 0.57 * b2 + w * 1.0527;
    bruit[i] = b0 + b1 + b2 + w * 0.1848 + 0.6 * Math.sin((2 * Math.PI * 95 * i) / FREQ);
  }
  const rmsBruit = Math.sqrt(bruit.reduce((t, v) => t + v * v, 0) / bruit.length);
  return voix.map((v, i) => Math.max(-32768, Math.min(32767, Math.round(v + (bruit[i]! * cible) / rmsBruit))));
}

async function synthetiser(texte: string, voix: string): Promise<Int16Array> {
  for (let essai = 0; essai < 4; essai++) {
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODELE_TTS}:generateContent`,
      {
        method: 'POST',
        headers: { 'x-goog-api-key': CLE_GOOGLE, 'content-type': 'application/json' },
        body: JSON.stringify({
          contents: [{ parts: [{ text: CONSIGNE + texte }] }],
          generationConfig: {
            responseModalities: ['AUDIO'],
            speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voix } } },
          },
        }),
      },
    );
    if (r.status === 429 || r.status >= 500) {
      await new Promise((ok) => setTimeout(ok, 4000 * (essai + 1)));
      continue;
    }
    const j = (await r.json()) as {
      candidates?: { content?: { parts?: { inlineData?: { data: string; mimeType: string } }[] } }[];
      error?: { message?: string };
    };
    const donnees = j.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
    if (!donnees) throw new Error(`synthèse impossible : ${j.error?.message ?? r.status}`);
    const taux = Number(/rate=(\d+)/.exec(donnees.mimeType)?.[1] ?? 24000);
    return reechantillonner(Buffer.from(donnees.data, 'base64'), taux);
  }
  throw new Error('synthèse : trop de refus');
}

interface Son { fichier: string; phrase: Phrase; voix: string; bruit: boolean }

async function preparerSons(): Promise<Son[]> {
  mkdirSync(DOSSIER, { recursive: true });
  const sons: Son[] = [];
  const i_ = process.argv.indexOf('--limite');
  const limite = i_ > 0 ? Number(process.argv[i_ + 1]) : PHRASES.length;
  for (const [i, phrase] of PHRASES.slice(0, limite).entries()) {
    const voix = VOIX[i % VOIX.length]!;
    const propre = join(DOSSIER, `${String(i).padStart(2, '0')}-${voix}-propre.wav`);
    const bruite = join(DOSSIER, `${String(i).padStart(2, '0')}-${voix}-rue.wav`);
    if (!existsSync(propre) || !existsSync(bruite)) {
      process.stdout.write(`synthèse ${i + 1}/${PHRASES.length}…\r`);
      const pcm = await synthetiser(phrase.texte, voix);
      writeFileSync(propre, wav(Buffer.from(pcm.buffer)));
      writeFileSync(bruite, wav(Buffer.from(bruiter(pcm, i + 7).buffer)));
    }
    sons.push({ fichier: propre, phrase, voix, bruit: false }, { fichier: bruite, phrase, voix, bruit: true });
  }
  return sons;
}

// ------------------------------------------------------------ mesures ----

interface Mesure { texte: string; attenteMs: number; miseEnRouteMs: number; premierMotMs: number | null }

const pause = (ms: number) => new Promise((ok) => setTimeout(ok, ms));

/** Envoie le son au rythme réel ; `fin` est appelé après le dernier morceau. */
async function diffuser(pcm: Buffer, envoyer: (m: Buffer, dernier: boolean) => void): Promise<number> {
  for (let i = 0; i < pcm.length; i += MORCEAU) {
    envoyer(pcm.subarray(i, i + MORCEAU), i + MORCEAU >= pcm.length);
    await pause(100);
  }
  return performance.now();
}

export async function gemini(pcm: Buffer): Promise<Mesure> {
  const t0 = performance.now();
  const setup = {
    model: MODELE_LIVE,
    generationConfig: { responseModalities: ['TEXT'] },
    inputAudioTranscription: {
      languageCodes: ['fr-FR', 'ha-NG'],
      // GEMINI_SANS_VOCABULAIRE=1 : mesurer l'effet de la liste (elle semblait
      // faire inventer des noms de lieux).
      ...(process.env.GEMINI_SANS_VOCABULAIRE ? {} : { customVocabulary: VOCABULAIRE }),
      mode: 'SMART',
    },
  };
  const expire = new Date(Date.now() + 2 * 60_000).toISOString();
  const rj = await fetch('https://generativelanguage.googleapis.com/v1alpha/auth_tokens', {
    method: 'POST',
    headers: { 'x-goog-api-key': CLE_GOOGLE, 'content-type': 'application/json' },
    body: JSON.stringify({ uses: 1, expireTime: expire, newSessionExpireTime: expire, bidiGenerateContentSetup: setup }),
  });
  const jeton = ((await rj.json()) as { name?: string }).name;
  if (!jeton) throw new Error(`jeton Gemini : ${rj.status}`);
  const ws = new WebSocket(
    `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=${encodeURIComponent(jeton)}`,
  );
  return recevoir(ws, t0, {
    ouvrir: () => ws.send(JSON.stringify({ setup })),
    pret: (m) => (m as { setupComplete?: unknown }).setupComplete !== undefined,
    envoyer: (morceau) =>
      ws.send(JSON.stringify({ realtimeInput: { audio: { data: morceau.toString('base64'), mimeType: `audio/pcm;rate=${FREQ}` } } })),
    terminer: () => ws.send(JSON.stringify({ realtimeInput: { audioStreamEnd: true } })),
    partiel: (m) => (m as { serverContent?: { interimInputTranscription?: { text?: string } } }).serverContent?.interimInputTranscription?.text,
    final: (m) => (m as { serverContent?: { inputTranscription?: { text?: string } } }).serverContent?.inputTranscription?.text,
    erreur: (m) => ((m as { error?: unknown }).error ? JSON.stringify((m as { error: unknown }).error) : undefined),
  }, pcm);
}

export async function eleven(pcm: Buffer): Promise<Mesure> {
  const t0 = performance.now();
  // Jeton à usage unique, comme le ferait le serveur Tovo : la clé ne va
  // jamais sur le téléphone.
  const rj = await fetch('https://api.elevenlabs.io/v1/single-use-token/realtime_scribe', {
    method: 'POST',
    headers: { 'xi-api-key': CLE_ELEVEN! },
  });
  const jeton = ((await rj.json()) as { token?: string }).token;
  if (!jeton) throw new Error(`jeton ElevenLabs : ${rj.status}`);
  const params = new URLSearchParams({
    model_id: 'scribe_v2_realtime',
    audio_format: 'pcm_16000',
    language_code: 'fr',
    commit_strategy: 'manual',
    token: jeton,
  });
  for (const mot of VOCABULAIRE) params.append('keyterms', mot);
  const ws = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${params}`);
  const type = (m: unknown) => (m as { message_type?: string; type?: string }).message_type ?? (m as { type?: string }).type;
  return recevoir(ws, t0, {
    ouvrir: () => {},
    pret: (m) => type(m) === 'session_started',
    envoyer: (morceau, dernier) =>
      ws.send(JSON.stringify({ message_type: 'input_audio_chunk', audio_base_64: morceau.toString('base64'), commit: dernier, sample_rate: FREQ })),
    terminer: () => {},
    partiel: (m) => (type(m) === 'partial_transcript' ? (m as { text?: string }).text : undefined),
    final: (m) => (type(m) === 'committed_transcript' ? (m as { text?: string }).text : undefined),
    erreur: (m) => (/error|exceeded|limited/.test(type(m) ?? '') ? JSON.stringify(m) : undefined),
  }, pcm);
}

interface Protocole {
  ouvrir: () => void;
  pret: (m: unknown) => boolean;
  envoyer: (morceau: Buffer, dernier: boolean) => void;
  terminer: () => void;
  partiel: (m: unknown) => string | undefined;
  final: (m: unknown) => string | undefined;
  erreur: (m: unknown) => string | undefined;
}

/**
 * Déroulé commun. Le texte final est complet quand plus rien n'arrive
 * pendant 1,5 s après la fin de la phrase ; l'attente retenue est l'heure du
 * DERNIER morceau de texte final — celle où l'app peut envoyer la demande.
 */
function recevoir(ws: WebSocket, t0: number, p: Protocole, pcm: Buffer): Promise<Mesure> {
  return new Promise((resoudre, rejeter) => {
    let debutSon = 0, finParole = 0, dernierFinal = 0, premierMot = 0, miseEnRoute = 0;
    const finaux: string[] = [];
    let calme: NodeJS.Timeout | undefined;
    const conclure = () => {
      clearTimeout(garde);
      try { ws.close(); } catch { /* déjà fermée */ }
      resoudre({
        texte: finaux.join(' ').trim(),
        attenteMs: dernierFinal && finParole ? Math.max(0, Math.round(dernierFinal - finParole)) : NaN,
        miseEnRouteMs: Math.round(miseEnRoute),
        premierMotMs: premierMot ? Math.round(premierMot - debutSon) : null,
      });
    };
    const garde = setTimeout(conclure, 25_000);
    ws.onopen = () => p.ouvrir();
    ws.onerror = () => rejeter(new Error('WebSocket en erreur'));
    ws.onmessage = async (e) => {
      const brut = typeof e.data === 'string' ? e.data : await (e.data as Blob).text();
      const m = JSON.parse(brut) as unknown;
      const err = p.erreur(m);
      if (err) { clearTimeout(garde); rejeter(new Error(err)); return; }
      if (p.pret(m)) {
        miseEnRoute = performance.now() - t0;
        debutSon = performance.now();
        finParole = await diffuser(pcm, p.envoyer);
        p.terminer();
        calme = setTimeout(conclure, 3000);
        return;
      }
      if (p.partiel(m) && !premierMot) premierMot = performance.now();
      const f = p.final(m);
      if (f?.trim()) {
        if (!premierMot) premierMot = performance.now();
        finaux.push(f.trim());
        dernierFinal = performance.now();
        if (finParole) { clearTimeout(calme); calme = setTimeout(conclure, 1500); }
      }
    };
  });
}

// ------------------------------------------------------------- scores ----

const normaliser = (t: string) =>
  t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();

function erreurMots(reference: string, hypothese: string): number {
  const r = normaliser(reference).split(' ');
  const h = normaliser(hypothese).split(' ').filter(Boolean);
  const d = Array.from({ length: r.length + 1 }, (_, i) => [i, ...Array(h.length).fill(0)] as number[]);
  for (let j = 1; j <= h.length; j++) d[0]![j] = j;
  for (let i = 1; i <= r.length; i++)
    for (let j = 1; j <= h.length; j++)
      d[i]![j] = Math.min(d[i - 1]![j]! + 1, d[i]![j - 1]! + 1, d[i - 1]![j - 1]! + (r[i - 1] === h[j - 1] ? 0 : 1));
  return d[r.length]![h.length]! / r.length;
}

/** Un mot clé est juste s'il figure (une de ses formes, séparées par |). */
const cleJuste = (cle: string, texte: string) =>
  cle.split('|').some((forme) => ` ${normaliser(texte)} `.includes(` ${normaliser(forme)}`));

const mediane = (v: number[]) => {
  const t = v.filter(Number.isFinite).sort((a, b) => a - b);
  return t.length ? t[Math.floor(t.length / 2)]! : NaN;
};
const centile = (v: number[], q: number) => {
  const t = v.filter(Number.isFinite).sort((a, b) => a - b);
  return t.length ? t[Math.min(t.length - 1, Math.floor(t.length * q))]! : NaN;
};

// -------------------------------------------------------------- banc ----

// Importé par banc-pause.ts : les fonctions seulement, pas le banc.
if (!process.argv.includes('--module')) {
  const sons = await preparerSons();
  console.log(`${sons.length} sons prêts (${PHRASES.length} phrases × propre/rue, voix ${VOIX.join(', ')})\n`);

  const fournisseurs: [string, (pcm: Buffer) => Promise<Mesure>][] = [];
  const seul = process.argv.find((a) => a === '--gemini' || a === '--eleven');
  if (seul !== '--eleven') fournisseurs.push(['Gemini Live', gemini]);
  if (seul !== '--gemini') {
    if (CLE_ELEVEN) fournisseurs.push(['ElevenLabs Scribe v2 RT', eleven]);
    else console.log('⚠ ELEVENLABS_API_KEY absente du .env : ElevenLabs sauté.\n');
  }

  const resultats: Record<string, { son: Son; mesure?: Mesure; echec?: string }[]> = {};
  for (const [nom] of fournisseurs) resultats[nom] = [];

  // Alternés son par son : un creux ou un pic du réseau touche les deux.
  for (const son of sons) {
    const pcm = readFileSync(son.fichier).subarray(44);
    for (const [nom, fn] of fournisseurs) {
      try {
        const mesure = await fn(pcm);
        resultats[nom]!.push({ son, mesure });
        console.log(
          `${nom.padEnd(24)} ${son.bruit ? 'rue   ' : 'propre'} ${String(mesure.attenteMs).padStart(5)} ms  « ${mesure.texte} »`,
        );
      } catch (cause) {
        resultats[nom]!.push({ son, echec: (cause as Error).message });
        console.log(`${nom.padEnd(24)} ÉCHEC : ${(cause as Error).message.slice(0, 160)}`);
      }
    }
  }

  console.log('\n==================== synthèse ====================');
  for (const [nom, lignes] of Object.entries(resultats)) {
    for (const bruit of [false, true]) {
      const l = lignes.filter((x) => x.son.bruit === bruit && x.mesure);
      const cles = l.flatMap((x) => x.son.phrase.cles.map((c) => cleJuste(c, x.mesure!.texte)));
      console.log(
        `${nom.padEnd(24)} ${bruit ? 'rue   ' : 'propre'}` +
          ` | attente après la phrase : médiane ${mediane(l.map((x) => x.mesure!.attenteMs))} ms, p90 ${centile(l.map((x) => x.mesure!.attenteMs), 0.9)} ms` +
          ` | mots faux ${Math.round((100 * l.reduce((t, x) => t + erreurMots(x.son.phrase.texte, x.mesure!.texte), 0)) / Math.max(1, l.length))} %` +
          ` | mots clés justes ${cles.filter(Boolean).length}/${cles.length}` +
          ` | mise en route ${mediane(l.map((x) => x.mesure!.miseEnRouteMs))} ms` +
          ` | échecs ${lignes.filter((x) => x.son.bruit === bruit && x.echec).length}`,
      );
    }
  }
  // Détail des mots clés ratés : c'est là que se joue la commande.
  for (const [nom, lignes] of Object.entries(resultats)) {
    const rates = lignes.filter((x) => x.mesure).flatMap((x) =>
      x.son.phrase.cles.filter((c) => !cleJuste(c, x.mesure!.texte)).map((c) => `${c} (${x.son.bruit ? 'rue' : 'propre'} : « ${x.mesure!.texte} »)`),
    );
    console.log(`\n${nom} — mots clés ratés (${rates.length}) :\n  ${rates.join('\n  ') || 'aucun'}`);
  }
  process.exit(0);
}
