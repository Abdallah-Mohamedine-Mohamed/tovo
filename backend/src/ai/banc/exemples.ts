import { serviceClient } from '../../services/supabase.js';
import type { FastifyBaseLogger } from 'fastify';
import { cleDe } from './boucle.js';

/**
 * Les EXEMPLES TIRÉS AU BON MOMENT : à chaque message, le cerveau voit les
 * phrases validées de la banque qui ressemblent le plus à celle du client, et
 * ce qu'elles voulaient dire. Il ne retient rien : c'est la banque qui grandit
 * (boucle du banc), et plus elle grandit, plus il a d'exemples proches.
 *
 * Empreintes : le petit modèle LOCAL multilingual-e5-small (~20 ms, aucun
 * réseau) — une empreinte Gemini coûtait ~400 ms par message. Les empreintes
 * de la banque sont calculées une fois, en mémoire, et complétées toutes les
 * 10 minutes.
 *
 * Honnêteté de l'examen : une phrase sur cinq de la banque (tirée par sa clé,
 * donc toujours la même) est RÉSERVÉE à l'examen et n'est jamais montrée
 * comme exemple. Sinon l'examen mesurerait la mémoire, pas la compréhension.
 */

export type ReponseAttendue = 'intention' | 'tuiles' | 'erronee';

export interface Exemple {
  texte: string;
  avant: string | null;
  attendu: string;
  reponse: ReponseAttendue;
  tuiles: string[] | null;
  cle: string;
}

/** Une phrase sur cinq, toujours la même : réservée à l'examen. */
export function estReserve(cle: string): boolean {
  let h = 0x811c9dc5;
  for (let i = 0; i < cle.length; i++) {
    h ^= cle.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h % 5 === 0;
}

export type Empreinter = (textes: string[]) => Promise<Float32Array[]>;

/** L'index en mémoire : des empreintes normées, comparées par produit scalaire. */
export class IndexExemples {
  private readonly exemples: Exemple[] = [];
  private readonly vecteurs: Float32Array[] = [];
  private readonly cles = new Set<string>();

  get taille(): number {
    return this.exemples.length;
  }

  connait(cle: string): boolean {
    return this.cles.has(cle);
  }

  ajouter(exemples: Exemple[], vecteurs: Float32Array[]): void {
    exemples.forEach((e, i) => {
      if (this.cles.has(e.cle) || !vecteurs[i]) return;
      this.cles.add(e.cle);
      this.exemples.push(e);
      this.vecteurs.push(vecteurs[i]!);
    });
  }

  /** Les `k` plus proches (sauf la phrase elle-même), au-dessus de `seuil`. */
  proches(vecteur: Float32Array, k: number, exclure?: string, seuil = 0.8): Exemple[] {
    const scores: Array<[number, number]> = [];
    for (let i = 0; i < this.vecteurs.length; i++) {
      if (this.exemples[i]!.cle === exclure) continue;
      const v = this.vecteurs[i]!;
      let s = 0;
      for (let d = 0; d < v.length; d++) s += v[d]! * vecteur[d]!;
      if (s >= seuil) scores.push([s, i]);
    }
    return scores.sort((a, b) => b[0] - a[0]).slice(0, k).map(([, i]) => this.exemples[i]!);
  }
}

/** Le bloc ajouté au message du cerveau. */
export function blocExemples(exemples: Exemple[]): string {
  if (exemples.length === 0) return '';
  const ligne = (e: Exemple) => {
    const contexte = e.avant ? ` (en réponse à « ${e.avant.replace(/\s+/g, ' ').slice(0, 120)} »)` : '';
    const sens = e.reponse === 'tuiles'
      ? `ambiguë (${(e.tuiles ?? []).join(' ou ') || 'plusieurs lectures'}) → "sur": false`
      : e.reponse === 'erronee'
        ? 'incompréhensible → "sur": false'
        : e.attendu;
    return `- « ${e.texte} »${contexte} → ${sens}`;
  };
  return ['Phrases proches déjà comprises (vérifiées), pour t’aider :', ...exemples.map(ligne)].join('\n');
}

// ── Le modèle local et la banque ────────────────────────────────────────

let empreinterLocal: Promise<Empreinter> | null = null;

/** Le modèle local (chargé une fois, à la première demande). */
export function modeleLocal(): Promise<Empreinter> {
  empreinterLocal ??= (async () => {
    const { pipeline } = await import('@huggingface/transformers');
    const extracteur = await pipeline('feature-extraction', 'Xenova/multilingual-e5-small', { dtype: 'q8' });
    return async (textes: string[]) => {
      const sorties: Float32Array[] = [];
      for (const t of textes) {
        const r = await extracteur(`query: ${t}`, { pooling: 'mean', normalize: true });
        sorties.push(new Float32Array(r.data as Float32Array));
      }
      return sorties;
    };
  })();
  return empreinterLocal;
}

/** Les exemples montrables : validés, et pas réservés à l'examen. */
export async function lireBanque(): Promise<Exemple[]> {
  const db = serviceClient();
  let lecture = await db.from('banc_cas').select('texte, avant, attendu, reponse, tuiles, cle').eq('statut', 'valide').limit(50_000);
  // Migration 0066 pas encore appliquée : tout est « un sens unique ».
  if (lecture.error) {
    lecture = await db.from('banc_cas').select('texte, avant, attendu, cle').eq('statut', 'valide').limit(50_000) as typeof lecture;
  }
  if (lecture.error) return [];
  return ((lecture.data ?? []) as Array<Record<string, unknown>>)
    .map((l) => ({
      texte: String(l.texte),
      avant: (l.avant as string | null) ?? null,
      attendu: String(l.attendu),
      reponse: ((l.reponse as ReponseAttendue | undefined) ?? 'intention'),
      tuiles: (l.tuiles as string[] | null | undefined) ?? null,
      cle: String(l.cle ?? cleDe(String(l.texte), l.avant as string | null)),
    }))
    .filter((e) => !estReserve(e.cle));
}

const index = new IndexExemples();
let pret = false;

/** Complète l'index avec les nouvelles phrases validées. */
export async function rafraichirExemples(): Promise<number> {
  const empreinter = await modeleLocal();
  const nouveaux = (await lireBanque()).filter((e) => !index.connait(e.cle));
  for (let i = 0; i < nouveaux.length; i += 64) {
    const lot = nouveaux.slice(i, i + 64);
    index.ajouter(lot, await empreinter(lot.map((e) => e.texte)));
  }
  pret = true;
  return nouveaux.length;
}

/** Au démarrage du serveur : charge en arrière-plan, puis complète toutes les 10 minutes. */
export function demarrerExemples(log: FastifyBaseLogger): () => void {
  const charger = () => rafraichirExemples()
    .then((n) => { if (n > 0) log.info({ nouveaux: n, total: index.taille }, 'exemples du cerveau : index complété'); })
    .catch((cause) => log.warn({ erreur: cause instanceof Error ? cause.message : String(cause) }, 'exemples du cerveau indisponibles'));
  void charger();
  const minuterie = setInterval(() => void charger(), 10 * 60_000);
  minuterie.unref();
  return () => clearInterval(minuterie);
}

/**
 * Les exemples proches d'un message, ou rien si l'index n'est pas prêt.
 * N'attend jamais le chargement du modèle : un message ne patiente pas.
 */
export async function exemplesPour(message: string, k = 8): Promise<Exemple[]> {
  if (!pret || !message.trim() || index.taille === 0) return [];
  const [vecteur] = await (await modeleLocal())([message]);
  return vecteur ? index.proches(vecteur, k, cleDe(message)) : [];
}
