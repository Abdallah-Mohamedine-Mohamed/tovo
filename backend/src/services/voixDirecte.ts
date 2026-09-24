import type { SupabaseClient } from '@supabase/supabase-js';
import { env } from '../config/env.js';

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
const MOTS_LOCAUX = [
  'attiéké', 'doukounou', 'kilichi', 'dambou', 'fura', 'massa', 'tuo', 'garba', 'alloco', 'bissap',
  'dèguè', 'gingembre', 'chawarma', 'tchapalo', 'wassa-wassa', 'foura', 'brochettes', 'Tovo',
  'Yantala', 'Plateau', 'Harobanda', 'Francophonie', 'Koira Kano', 'Lazaret', 'Niamey 2000', 'Talladjé',
];

let vocabulaireEnCache: { quand: number; mots: string[] } | null = null;

/** Mots locaux + noms d'enseignes (sans le quartier entre parenthèses). 10 min de cache. */
export async function vocabulaire(db: SupabaseClient): Promise<string[]> {
  if (vocabulaireEnCache && Date.now() - vocabulaireEnCache.quand < 10 * 60_000) return vocabulaireEnCache.mots;
  const { data } = await db.from('merchants').select('name').eq('is_approved', true).limit(300);
  const enseignes = (data ?? [])
    .map((m) => String(m.name).replace(/\([^)]*\)/g, '').replace(/\s+/g, ' ').trim())
    .filter((n) => n.length >= 3);
  const mots = [...new Set([...MOTS_LOCAUX, ...enseignes])].slice(0, 200);
  vocabulaireEnCache = { quand: Date.now(), mots };
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
