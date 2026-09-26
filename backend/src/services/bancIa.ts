import type { FastifyBaseLogger } from 'fastify';
import { env } from '../config/env.js';
import { serviceClient } from './supabase.js';

/**
 * La boucle du banc IA, lancée par le serveur lui-même : pas de tâche à
 * configurer ailleurs (demande du client, 26/09).
 *
 * Chaque minute, le serveur relit les réglages de l'admin (platform_settings :
 * en service ou non, toutes les N minutes, combien de phrases à écrire) et
 * lance un passage si le dernier date de plus de N minutes. Un seul passage à
 * la fois ; un passage raté n'arrête rien, le suivant réessaie.
 *
 * Le passage (ai/banc/passage.ts) ne touche ni aux commandes ni au catalogue :
 * il lit les conversations, écrit dans banc_cas et banc_passages.
 */

interface Reglages {
  actif: boolean;
  intervalleMin: number;
  phrases: number;
}

async function lireReglages(): Promise<Reglages | null> {
  const { data, error } = await serviceClient()
    .from('platform_settings')
    .select('banc_ia_actif, banc_ia_intervalle_min, banc_ia_phrases')
    .limit(1)
    .maybeSingle();
  // Colonnes absentes : la migration 0065 n'est pas encore appliquée.
  if (error || !data) return null;
  return {
    actif: data.banc_ia_actif !== false,
    intervalleMin: Number(data.banc_ia_intervalle_min ?? 30),
    phrases: Number(data.banc_ia_phrases ?? 30),
  };
}

async function dernierPassage(): Promise<number | null> {
  const { data } = await serviceClient().from('banc_passages').select('cree_le').order('cree_le', { ascending: false }).limit(1);
  const le = data?.[0]?.cree_le as string | undefined;
  return le ? Date.parse(le) : null;
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
      const dernier = await dernierPassage();
      if (dernier !== null && Date.now() - dernier < reglages.intervalleMin * 60_000) return;
      const { passageDuBanc } = await import('../ai/banc/passage.js');
      log.info({ phrases: reglages.phrases }, 'banc IA : passage');
      const { rapport } = await passageDuBanc({ phrases: reglages.phrases });
      log.info({
        duree_s: rapport.duree_s,
        reels: rapport.reels,
        synthetiques: { ecrites: rapport.synthetiques.ecrites, gardees: rapport.synthetiques.gardees },
        justesse: rapport.examen.justesse,
        couteuses_a_tort: rapport.examen.actions_couteuses_a_tort,
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
