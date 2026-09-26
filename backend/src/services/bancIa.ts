import type { FastifyBaseLogger } from 'fastify';
import { env } from '../config/env.js';
import { serviceClient } from './supabase.js';

/**
 * La boucle du banc IA, lancée par le serveur lui-même : pas de tâche à
 * configurer ailleurs (demande du client, 26/09).
 *
 * Chaque minute, le serveur relit les réglages de l'admin (platform_settings :
 * en service ou non, toutes les N minutes, combien de phrases à écrire,
 * l'examen toutes les M minutes) et lance un passage si le dernier date de
 * plus de N minutes. L'examen complet n'est refait que toutes les M minutes :
 * il interroge l'assistant avec la même clé Gemini que les clients. Un seul passage à
 * la fois ; un passage raté n'arrête rien, le suivant réessaie.
 *
 * Le passage (ai/banc/passage.ts) ne touche ni aux commandes ni au catalogue :
 * il lit les conversations, écrit dans banc_cas et banc_passages.
 */

interface Reglages {
  actif: boolean;
  intervalleMin: number;
  phrases: number;
  examenMin: number;
}

async function lireReglages(): Promise<Reglages | null> {
  const db = serviceClient();
  let lecture = await db.from('platform_settings')
    .select('banc_ia_actif, banc_ia_intervalle_min, banc_ia_phrases, banc_ia_examen_min').limit(1).maybeSingle();
  // Migration 0066 pas encore appliquée : sans le rythme de l'examen.
  if (lecture.error) {
    lecture = await db.from('platform_settings')
      .select('banc_ia_actif, banc_ia_intervalle_min, banc_ia_phrases').limit(1).maybeSingle() as typeof lecture;
  }
  // Colonnes absentes : la migration 0065 n'est pas encore appliquée.
  const data = lecture.data as Record<string, unknown> | null;
  if (lecture.error || !data) return null;
  return {
    actif: data.banc_ia_actif !== false,
    intervalleMin: Number(data.banc_ia_intervalle_min ?? 30),
    phrases: Number(data.banc_ia_phrases ?? 30),
    examenMin: Number(data.banc_ia_examen_min ?? 60),
  };
}

/** Le dernier passage, et le dernier qui a fait passer l'examen. */
async function derniersPassages(): Promise<{ passage: number | null; examen: number | null }> {
  const db = serviceClient();
  const { data } = await db.from('banc_passages').select('cree_le, rapport').order('cree_le', { ascending: false }).limit(50);
  const lignes = (data ?? []) as Array<{ cree_le: string; rapport: { examen?: unknown } | null }>;
  const date = (l?: { cree_le: string }) => (l ? Date.parse(l.cree_le) : null);
  return { passage: date(lignes[0]), examen: date(lignes.find((l) => l.rapport?.examen)) };
}

export function demarrerBancIa(log: FastifyBaseLogger): () => void {
  // Sans les deux modèles forts, pas de boucle (ni en test).
  if (env.NODE_ENV === 'test' || !env.GEMINI_API_KEY || !env.OPENAI_API_KEY) return () => {};
  let enCours = false;

  const verifier = async () => {
    if (enCours) return;
    enCours = true;
    try {
      const reglages = await lireReglages();
      if (!reglages?.actif) return;
      const derniers = await derniersPassages();
      if (derniers.passage !== null && Date.now() - derniers.passage < reglages.intervalleMin * 60_000) return;
      const examiner = derniers.examen === null || Date.now() - derniers.examen >= reglages.examenMin * 60_000;
      const { passageDuBanc } = await import('../ai/banc/passage.js');
      log.info({ phrases: reglages.phrases, examiner }, 'banc IA : passage');
      const { rapport } = await passageDuBanc({ phrases: reglages.phrases, examiner });
      log.info({
        duree_s: rapport.duree_s,
        reels: rapport.reels,
        synthetiques: { ecrites: rapport.synthetiques.ecrites, gardees: rapport.synthetiques.gardees },
        ...(rapport.examen ? {
          justesse: rapport.examen.justesse,
          couteuses_a_tort: rapport.examen.actions_couteuses_a_tort,
        } : {}),
        failles: rapport.nouvelles_failles.length,
      }, 'banc IA : passage terminé');
    } catch (cause) {
      log.error({ erreur: cause instanceof Error ? cause.message : String(cause) }, 'banc IA : passage impossible');
    } finally {
      enCours = false;
    }
  };

  // Premier regard deux minutes après le démarrage : le serveur sert d'abord
  // les clients.
  const premier = setTimeout(() => void verifier(), 2 * 60_000);
  const minuterie = setInterval(() => void verifier(), 60_000);
  premier.unref();
  minuterie.unref();
  return () => {
    clearTimeout(premier);
    clearInterval(minuterie);
  };
}
