import type { SupabaseClient } from '@supabase/supabase-js';
import { MOTS_LOCAUX as MOTS_DU_CATALOGUE } from '../ai/vocabulaireLocal.js';
import { env } from '../config/env.js';
import { chargerLieux } from './lieux.js';
import { normaliserIntention } from '../ai/intents.js';

/**
 * Voix en direct : le téléphone parle DIRECTEMENT à Gemini Live
 * (gemini-3.5-transcribe-live), avec un jeton temporaire délivré ici.
 *
 * Avant : enregistrer tout le message, l'envoyer à la fin, attendre la
 * transcription — 2 à 4 s après la dernière syllabe, sans rien voir pendant
 * qu'on parle. Maintenant : le son part par morceaux de 100 ms pendant la
 * parole, les mots s'affichent au fil de l'eau, et le texte final est prêt
 * ~0,4 s après la fin (mesuré le 24/09, scripts/voix/prototype.ts).
 *
 * La clé Google ne quitte jamais le serveur. Le jeton est à usage UNIQUE,
 * expire en 2 minutes, et verrouille modèle, langues et vocabulaire : le
 * téléphone ne peut rien en faire d'autre que transcrire un message.
 */

export const MODELE_VOIX = 'models/gemini-3.5-transcribe-live';
export const URL_VOIX =
  'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';

/**
 * Mots que Gemini ne devinerait pas seul : plats et enseignes de Niamey.
 * « O'Takoss », « bissap », « Yantala » sortaient justes au prototype grâce
 * à cette liste.
 */
// Les plats et aliments locaux viennent du vocabulaire construit à partir du
// catalogue (ai/vocabulaireLocal.ts, 05/10 : placali manquait) ; ici, les
// quartiers et le nom de l'application.
const MOTS_LOCAUX = [
  ...MOTS_DU_CATALOGUE.map((m) => m.mot), 'gingembre', 'brochettes', 'Tovo',
  'Yantala', 'Plateau', 'Harobanda', 'Francophonie', 'Koira Kano', 'Lazaret', 'Niamey 2000', 'Talladjé',
];

/**
 * Tous les quartiers de Niamey (OpenStreetMap, data/lieux-niamey.json), sans
 * leur numéro (« Boukoki 1 » → « Boukoki »). 09/10 : « Bobiel » était
 * transcrit « BOBA » — le nom d'une boutique de la liste, le seul mot proche
 * que le modèle connaissait. Avec les quartiers, il a le bon mot.
 */
export function quartiersDeNiamey(): string[] {
  const noms = chargerLieux()
    .filter((l) => l.genre === 'quartier')
    .map((l) => l.nom.replace(/\s+\d+$/, '').trim())
    .filter((n) => n.length >= 3)
    // Les plus courts d'abord : un nom qui en contient un autre (« Yantala
    // Haut », « Nord Lazaret ») n'apprend rien de plus au modèle.
    .sort((a, b) => a.length - b.length || a.localeCompare(b, 'fr'));
  const gardes: string[] = [];
  for (const nom of noms) {
    const n = ` ${normaliserIntention(nom)} `;
    if (gardes.some((g) => n.includes(` ${normaliserIntention(g)} `))) continue;
    gardes.push(nom);
  }
  return gardes;
}

/** MAI-Transcribe refuse une liste de plus de 200 mots (HTTP 400, mesuré le 09/10). */
export const LIMITE_MOTS_MAI = 200;

let vocabulaireEnCache: { quand: number; mots: string[] } | null = null;

/**
 * Mots locaux, quartiers, puis noms d'enseignes (sans le quartier entre
 * parenthèses). 10 min de cache. Azure accepte 500 phrases : 300 suffisent.
 * `avecQuartiers: false` : la liste d'avant le 09/10 (banc de comparaison).
 */
export async function vocabulaire(db: SupabaseClient, options: { avecQuartiers?: boolean } = {}): Promise<string[]> {
  const avecQuartiers = options.avecQuartiers ?? true;
  if (avecQuartiers && vocabulaireEnCache && Date.now() - vocabulaireEnCache.quand < 10 * 60_000) return vocabulaireEnCache.mots;
  const { data } = await db.from('merchants').select('name').eq('is_approved', true).limit(300);
  const enseignes = (data ?? [])
    .map((m) => String(m.name).replace(/\([^)]*\)/g, '').replace(/\s+/g, ' ').trim())
    .filter((n) => n.length >= 3);
  // Les plats et les enseignes d'abord (les commandes) ; les quartiers
  // prennent la place qui reste, sans jamais dépasser la limite de MAI.
  const base = [...new Set([...MOTS_LOCAUX, ...enseignes])].slice(0, LIMITE_MOTS_MAI);
  const dejaLa = new Set(base.map((m) => normaliserIntention(m)));
  const quartiers = avecQuartiers
    ? quartiersDeNiamey().filter((q) => !dejaLa.has(normaliserIntention(q))).slice(0, LIMITE_MOTS_MAI - base.length)
    : [];
  const mots = [...MOTS_LOCAUX.filter((m) => base.includes(m)), ...quartiers, ...base.filter((m) => !MOTS_LOCAUX.includes(m))];
  if (avecQuartiers) vocabulaireEnCache = { quand: Date.now(), mots };
  return mots;
}

export interface SessionVoix { jeton: string; url: string; modele: string; configuration: Record<string, unknown> }

/** Délivre un jeton temporaire, ou `null` si Gemini n'est pas configuré ou refuse. */
export async function ouvrirSessionVoix(db: SupabaseClient): Promise<SessionVoix | null> {
  if (!env.GEMINI_API_KEY) return null;
  const configuration = {
    model: MODELE_VOIX,
    generationConfig: { responseModalities: ['TEXT'] },
    inputAudioTranscription: { languageCodes: ['fr-FR', 'ha-NG'], customVocabulary: await vocabulaire(db), mode: 'SMART' },
  };
  const expire = new Date(Date.now() + 2 * 60_000).toISOString();
  const reponse = await fetch('https://generativelanguage.googleapis.com/v1alpha/auth_tokens', {
    method: 'POST',
    headers: { 'x-goog-api-key': env.GEMINI_API_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ uses: 1, expireTime: expire, newSessionExpireTime: expire, bidiGenerateContentSetup: configuration }),
    signal: AbortSignal.timeout(5_000),
  });
  if (!reponse.ok) return null;
  const corps = (await reponse.json()) as { name?: string };
  if (!corps.name) return null;
  // La configuration est renvoyée au téléphone : il doit l'envoyer telle
  // quelle à l'ouverture, elle doit correspondre à celle du jeton.
  return { jeton: corps.name, url: URL_VOIX, modele: MODELE_VOIX, configuration };
}
