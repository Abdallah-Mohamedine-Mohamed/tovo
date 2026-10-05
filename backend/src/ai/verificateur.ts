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
  /**
   * Les actions que les données CONFIRMENT (article 4 de la constitution) :
   * « gardee » (une précision enregistrée, un signalement transmis),
   * « commande » (une commande ou une course existe).
   */
  private readonly actions = new Set<'gardee' | 'commande' | 'annulee' | 'proche' | 'ailleurs'>();
  /** Les numéros de téléphone que les données OU le client ont donnés (article 13). */
  private readonly telephones = new Set<string>();

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
      for (const t of telephonesDans(valeur)) this.telephones.add(t);
      return;
    }
    if (Array.isArray(valeur)) {
      for (const v of valeur.slice(0, 200)) this.ajouter(v, profondeur + 1);
      return;
    }
    if (typeof valeur === 'object') {
      const o = valeur as Record<string, unknown>;
      if (o.enregistree === true || o.signale === true) this.actions.add('gardee');
      if (typeof o.order_id === 'string' || o.livreur_assigne === true) this.actions.add('commande');
      if (o.annulee === true || o.status === 'cancelled') this.actions.add('annulee');
      // Un lieu montré à moins de 2 km : « près de vous » devient vrai.
      if (typeof o.distance_m === 'number' && o.distance_m < 2000) this.actions.add('proche');
      // Des commerces hors Tovo réellement montrés : on peut y envoyer le client.
      if (o.commerces_hors_tovo || o.aussi_hors_tovo || o.boutique_hors_tovo || o.livreur) this.actions.add('ailleurs');
      for (const v of Object.values(o)) this.ajouter(v, profondeur + 1);
    }
  }

  confirme(action: 'gardee' | 'commande' | 'annulee' | 'proche' | 'ailleurs'): boolean {
    return this.actions.has(action);
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
    // Son propre numéro, ou celui qu'il donne, peut être repris (article 13).
    for (const t of telephonesDans(texte ?? '')) this.telephones.add(t);
  }

  connaitTelephone(chiffres: string): boolean {
    return this.telephones.has(chiffres);
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
  genre: 'montant' | 'duree' | 'nom' | 'action' | 'sante' | 'ton' | 'donnees';
  valeur: string;
}

/**
 * ARTICLE 4 de la constitution, garanti ici et non seulement demandé : une
 * phrase qui dit qu'une chose est FAITE n'est gardée que si les données le
 * confirment. Vu le 02/10 : « C'est bien noté pour sans oignons » alors que
 * rien n'était enregistré ; « un livreur se rend à votre position » avant
 * tout toucher.
 */
const DIT_GARDE = /\b(?:c.est (?:bien )?(?:not[ée]|gard[ée]|enregistr[ée]|transmis)|(?:bien )?not[ée]e?(?![\wà-ÿ])|j.ai (?:bien )?(?:not[ée]|gard[ée]|enregistr[ée]|transmis|signal[ée])|je l.ai (?:not[ée]|transmis|signal[ée])|(?:est|a été|sont|ont été) (?:not[ée]e?s?|transmise?s?|enregistr[ée]e?s?|signal[ée]e?s?))/i;
/**
 * ARTICLE 12 — la santé n'est pas notre métier : une dose, une posologie, un
 * médicament conseillé ne sortent jamais, quelles que soient les données.
 */
const DOSE = /\b(?:posologie|\d+(?:[.,]\d+)?\s?mg\b|(?:comprim[ée]s?|g[ée]lules?|cuill[èe]res?|doses?|sachets?) (?:par|chaque|toutes les) (?:jour|heure|repas|\d)|\d+\s?fois par jour|toutes les \d+\s?h(?:eures?)?\b)/i;
// Un conseil n'est médical que s'il porte sur un médicament : « je vous
// recommande le tacos » reste permis.
const CONSEILLER = /\b(?:je vous (?:conseille|recommande)|prenez|il faut prendre)\b/i;
const MEDICAMENT = /\b(?:m[ée]dicaments?|comprim[ée]s?|sirops?|g[ée]lules?|parac[ée]tamol|doliprane|efferalgan|ibuprof[èe]ne|aspirine|antibiotiques?|antipalud\w*|coartem|quinine)\b/i;
const CONSEIL_MEDICAL = {
  test: (p: string) => DOSE.test(p) || (CONSEILLER.test(p) && MEDICAMENT.test(p)),
  match: (p: string) => p.match(DOSE) ?? p.match(CONSEILLER),
};
/**
 * ARTICLE 14 — on vouvoie toujours, même si le client tutoie (vu le 02/10 :
 * « si tu as besoin d'autre chose »).
 */
const TUTOIEMENT = /(?:^|[\s,;:(«"'’])(?:tu|toi|ton|tes|te|t['’])(?=[\s,.!?;:)»"]|$)/i;
/** Un numéro de téléphone du Niger : 8 chiffres, avec ou sans +227. */
const TELEPHONE = /(?:\+?227[\s.]?)?\b\d{2}(?:[\s.]?\d{2}){3}\b/g;
function telephonesDans(texte: string): string[] {
  return [...texte.matchAll(TELEPHONE)].map((m) => m[0].replace(/\D/g, '').replace(/^227/, ''));
}

const DIT_ANNULE = /\b(?:c.est (?:bien )?annul[ée]|j.ai (?:bien )?annul[ée]|(?:est|a été) annul[ée]e?)/i;
/**
 * ARTICLE 5 : « près de vous », « à proximité » ne se disent que si un lieu
 * montré est vraiment à moins de 2 km (vu le 05/10 : « Nouhou Merguez, situé à
 * proximité » à 3,1 km).
 */
/**
 * ARTICLE 8 garanti : on n'envoie le client vers un TYPE de commerce (« les
 * librairies de Niamey », « une pharmacie ») que si des commerces lui sont
 * montrés. Vu le 05/10 : « consultez les librairies spécialisées de Niamey »,
 * deviné, sans aucune donnée.
 */
const ENVOIE_AILLEURS = /(?:je vous (?:invite|conseille|recommande)|vous (?:pouvez|pourriez) (?:essayer|consulter|vous rendre|aller|demander)|vous (?:en )?trouverez(?: probablement| sans doute| s[uû]rement)?|rendez-vous|essayez)[^.!?]*\b(?:librairies?|boutiques?|magasins?|pharmacies?|supermarch[ée]s?|march[ée]s?|commerces?|vendeurs?|[ée]piceries?|boulangeries?|quincailleries?)\b/i;
const DIT_PROCHE = /(?:^|[\s,;(«'’])(?:pr[eè]s de (?:chez )?vous|[aà] proximit[ée]|tout pr[eè]s|non loin de (?:chez )?vous|pas loin de (?:chez )?vous|juste [aà] c[oô]t[ée])/i;
const DIT_EN_ROUTE = /\b(?:(?:est|sont) en route|se rend\b|se rendra\b|se dirige|vous rejoint|est parti|arrive (?:chez|à) vous|vient chez vous)/i;

/** Les affirmations d'une phrase qui ne viennent pas des faits. */
export function affirmationsInventees(phrase: string, faits: Faits): Affirmation[] {
  const inventees: Affirmation[] = [];
  for (const m of phrase.matchAll(MONTANT)) {
    if (!faits.connaitNombre(lireNombre(m[1]!))) inventees.push({ genre: 'montant', valeur: m[0] });
  }
  for (const m of phrase.matchAll(DUREE)) {
    if (!faits.connaitNombre(Number(m[1]))) inventees.push({ genre: 'duree', valeur: m[0] });
  }
  if (DIT_GARDE.test(phrase) && !faits.confirme('gardee')) inventees.push({ genre: 'action', valeur: phrase.match(DIT_GARDE)![0] });
  if (DIT_EN_ROUTE.test(phrase) && !faits.confirme('commande')) inventees.push({ genre: 'action', valeur: phrase.match(DIT_EN_ROUTE)![0] });
  if (DIT_PROCHE.test(phrase) && !faits.confirme('proche')) inventees.push({ genre: 'action', valeur: phrase.match(DIT_PROCHE)![0] });
  if (ENVOIE_AILLEURS.test(phrase) && !faits.confirme('ailleurs')) inventees.push({ genre: 'action', valeur: phrase.match(ENVOIE_AILLEURS)![0] });
  if (DIT_ANNULE.test(phrase) && !faits.confirme('annulee')) inventees.push({ genre: 'action', valeur: phrase.match(DIT_ANNULE)![0] });
  if (CONSEIL_MEDICAL.test(phrase)) inventees.push({ genre: 'sante', valeur: CONSEIL_MEDICAL.match(phrase)?.[0] ?? phrase });
  if (TUTOIEMENT.test(phrase)) inventees.push({ genre: 'ton', valeur: phrase.match(TUTOIEMENT)![0].trim() });
  for (const t of telephonesDans(phrase)) {
    if (!faits.connaitTelephone(t)) inventees.push({ genre: 'donnees', valeur: t });
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
