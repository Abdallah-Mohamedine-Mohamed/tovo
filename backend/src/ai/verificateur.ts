import { normaliserIntention } from './intents.js';

/**
 * Le vérificateur : aucune phrase ne part si elle affirme un fait qui ne
 * vient pas de la base.
 *
 * Le modèle rédige ; les OUTILS savent. Chaque montant (« 6 800 F »), chaque
 * durée (« 7 minutes ») et chaque nom mis en avant (« **Royal tacos** ») d'une
 * réponse doit se retrouver dans ce que les outils ont renvoyé pendant ce
 * tour, dans ce qui était déjà affiché, ou dans la phrase du client. Sinon la
 * PHRASE entière est retirée — pas seulement le chiffre : une phrase amputée
 * de son prix dirait encore quelque chose de faux.
 *
 * Coût : de la comparaison de texte, moins d'une milliseconde. Rien n'est
 * redemandé au modèle.
 */

/** Ce qui est vrai pendant ce tour : nombres et noms, tels que la base les a donnés. */
export class Faits {
  private readonly nombres = new Set<number>();
  private readonly textes: string[] = [];

  /** Ajoute tout ce que contient une valeur (résumé d'outil, composant, texte). */
  ajouter(valeur: unknown, profondeur = 0): void {
    if (profondeur > 8 || valeur === null || valeur === undefined) return;
    if (typeof valeur === 'number' && Number.isFinite(valeur)) {
      this.nombres.add(Math.round(valeur));
      return;
    }
    if (typeof valeur === 'string') {
      const propre = normaliserIntention(valeur);
      if (propre) this.textes.push(propre);
      for (const n of nombresDans(valeur)) this.nombres.add(n);
      return;
    }
    if (Array.isArray(valeur)) {
      for (const v of valeur.slice(0, 200)) this.ajouter(v, profondeur + 1);
      return;
    }
    if (typeof valeur === 'object') {
      for (const v of Object.values(valeur as Record<string, unknown>)) this.ajouter(v, profondeur + 1);
    }
  }

  /**
   * Ce que le CLIENT a dit : ses mots servent à reconnaître un nom (« **merguez** »),
   * jamais à confirmer un montant ou une durée. « Il arrive dans 10 minutes ? »
   * laissait Tovo répondre « votre livreur arrive dans 10 minutes » : le
   * nombre venait de la question, pas de la base (évaluation externe, 02/10).
   */
  ajouterParole(texte: string | null | undefined): void {
    const propre = texte ? normaliserIntention(texte) : '';
    if (propre) this.textes.push(propre);
  }

  connaitNombre(n: number): boolean {
    return this.nombres.has(n);
  }

  /** Un nom mis en avant est-il un nom que la base (ou le client) a donné ? */
  connaitNom(nom: string): boolean {
    const cherche = normaliserIntention(nom);
    if (!cherche) return true;
    const mots = cherche.split(' ').filter((m) => m.length >= 3);
    return this.textes.some((t) => t.includes(cherche) || (cherche.includes(t) && t.length >= 4)
      // Accord approximatif : l'essentiel des mots du nom figure dans un
      // même fait (« tacos poulet » pour « Tacos au poulet »).
      || (mots.length > 0 && mots.filter((m) => t.split(' ').includes(m)).length / mots.length >= 0.75));
  }
}

/** « 6 800 », « 6.800 », « 6800 » → 6800. */
function lireNombre(brut: string): number {
  return Number(brut.replace(/[\s.  ]/g, ''));
}

function nombresDans(texte: string): number[] {
  return [...texte.matchAll(/\d{1,3}(?:[ .  ]\d{3})+|\d+/g)].map((m) => lireNombre(m[0]));
}

const MONTANT = /(\d{1,3}(?:[ .  ]\d{3})+|\d+)\s*(?:F\b|FCFA|F CFA|francs?\b|XOF)/gi;
const DUREE = /(\d+)\s*(?:min\b|mins\b|minutes?\b|heures?\b|h\b)/gi;
const GRAS = /\*\*([^*]{2,80})\*\*/g;

export interface Affirmation {
  genre: 'montant' | 'duree' | 'nom';
  valeur: string;
}

/** Les affirmations d'une phrase qui ne viennent pas des faits. */
export function affirmationsInventees(phrase: string, faits: Faits): Affirmation[] {
  const inventees: Affirmation[] = [];
  for (const m of phrase.matchAll(MONTANT)) {
    if (!faits.connaitNombre(lireNombre(m[1]!))) inventees.push({ genre: 'montant', valeur: m[0] });
  }
  for (const m of phrase.matchAll(DUREE)) {
    if (!faits.connaitNombre(Number(m[1]))) inventees.push({ genre: 'duree', valeur: m[0] });
  }
  for (const m of phrase.matchAll(GRAS)) {
    const contenu = m[1]!.trim();
    const nombres = nombresDans(contenu);
    // « **241 produits** » : c'est le nombre qui doit être vrai.
    if (nombres.length > 0) {
      if (nombres.some((n) => !faits.connaitNombre(n))) inventees.push({ genre: 'nom', valeur: contenu });
    } else if (!faits.connaitNom(contenu)) {
      inventees.push({ genre: 'nom', valeur: contenu });
    }
  }
  return inventees;
}

/**
 * Découpe en phrases, ponctuation et espaces qui suivent compris. Un point
 * DANS un nombre (« 6.800 ») ne coupe pas : seul un point suivi d'un espace,
 * ou de la fin, termine une phrase.
 */
export function phrases(texte: string): string[] {
  return texte.match(/(?:[^.!?\n]|[.!?](?![\s.!?]|$))+(?:[.!?]+(?=\s|$))?[^\S\n]*|[.!?]+[^\S\n]*|\n+/g)
    ?.filter((p) => p.length > 0) ?? [];
}

export interface Verification {
  texte: string;
  /** Le texte gardé, espaces compris (pour un flux qui continue). */
  brut: string;
  retirees: Array<{ phrase: string; inventees: Affirmation[] }>;
}

/** Retire chaque phrase qui affirme un fait inconnu. */
export function verifierTexte(texte: string, faits: Faits): Verification {
  const retirees: Verification['retirees'] = [];
  const gardees = phrases(texte).filter((phrase) => {
    const inventees = affirmationsInventees(phrase, faits);
    if (inventees.length === 0) return true;
    retirees.push({ phrase: phrase.trim(), inventees });
    return false;
  });
  const brut = gardees.join('');
  return { texte: brut.replace(/\n{3,}/g, '\n\n').trim(), brut, retirees };
}

/**
 * Le même contrôle, phrase par phrase, sur une réponse qui s'affiche au fil
 * de l'eau : une phrase ne part que COMPLÈTE et vérifiée. Le client voit la
 * réponse arriver par phrases plutôt que par mots — la durée totale ne
 * change pas.
 */
export class FluxVerifie {
  private enAttente = '';
  readonly retirees: Verification['retirees'] = [];

  constructor(
    private readonly faits: Faits,
    private readonly emettre: (texte: string) => void,
  ) {}

  pousser(fragment: string): void {
    this.enAttente += fragment;
    const morceaux = phrases(this.enAttente);
    // La dernière phrase n'est peut-être pas finie : on la garde.
    const derniere = morceaux[morceaux.length - 1] ?? '';
    // Finie seulement si un espace SUIT la ponctuation : « à 6. » peut
    // encore devenir « à 6.800 F » au fragment suivant.
    const finie = /[.!?]\s+$|\n$/.test(derniere);
    const pretes = finie ? morceaux : morceaux.slice(0, -1);
    this.enAttente = finie ? '' : derniere;
    this.envoyer(pretes.join(''));
  }

  terminer(): void {
    const reste = this.enAttente;
    this.enAttente = '';
    this.envoyer(reste);
  }

  private envoyer(texte: string): void {
    if (!texte) return;
    const v = verifierTexte(texte, this.faits);
    this.retirees.push(...v.retirees);
    // Le texte gardé tel quel, espaces compris : les phrases suivantes
    // s'y collent sans perdre leur séparation.
    if (v.brut.trim()) this.emettre(v.brut);
  }
}
