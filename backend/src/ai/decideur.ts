import { env } from '../config/env.js';
import { INTENTIONS, type Intention } from './jev.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';

/**
 * Le cerveau : un modèle COMPREND le message et décide de la route.
 *
 * Remplace la cascade classifieur local + Jev, qui devinait sur les mots :
 * « Je veux devenir livreur » commandait un livreur, « un colis de riz »
 * ouvrait un envoi de colis. Banc du 26/09 (scripts/banc-ia, 193 phrases
 * réelles et pièges) avec CETTE consigne : Flash-Lite 3.1 sans réflexion,
 * 96 % de justesse et AUCUNE action coûteuse à tort, contre 85 % et 6 pour la
 * cascade — en 0,9 s de médiane.
 *
 * Vitesse : la réponse tient en quelques mots (un JSON court), sans
 * réflexion interne, et trois filets coupent la traîne lente et les pannes :
 *   1. relance — sans réponse au bout de CERVEAU_RELANCE_MS, un second
 *      modèle (Flash-Lite 3.5, 0,7 s) part en parallèle : le premier qui
 *      répond gagne ;
 *   2. panne — une erreur de Google lance aussitôt le suivant, sans attendre ;
 *   3. dernier recours — OpenAI si les deux modèles Google échouent.
 * Au-delà de CERVEAU_DELAI_MAX_MS : `intention: null`, le chemin habituel
 * reprend (il ne déclenche jamais d'action coûteuse sans confirmation).
 *
 * Ne lève jamais.
 */

export const COUTEUSES = new Set<Intention>(['livreur', 'colis', 'annuler', 'habitude']);

/**
 * La consigne. Exportée : le banc (scripts/banc-ia) mesure EXACTEMENT celle-ci.
 *
 * Les exemples ne reprennent pas les phrases du banc : ils enseignent la
 * règle, le banc vérifie qu'elle est comprise sur d'autres phrases.
 */
export const CONSIGNE_CERVEAU = [
  'Tu comprends les messages des clients de Tovo, une application de livraison à Niamey (Niger) : repas, courses et colis.',
  'Tu ne réponds pas au client : tu dis seulement ce qu’il veut faire.',
  '',
  'Intentions possibles :',
  ...Object.entries(INTENTIONS).map(([cle, def]) => `- ${cle} : ${def}`),
  '',
  'Règles :',
  '- livreur / colis : le client veut qu’un livreur SE DÉPLACE pour lui (venir le voir, aller chercher ou déposer un objet à lui). Faire livrer un PRODUIT du catalogue, même avec « livre-moi », « apporte-moi » ou « envoie … chez ma mère », c’est recherche.',
  '- Un objet qui ressemble à un mot de livraison reste un produit : un livre, un litre, un paquet de biscuits, un sac ou un « colis » de riz → recherche.',
  '- Parler d’un livreur DÉJÀ en route (où il est, retard, ne répond pas) → suivi. Parler du MÉTIER de livreur (travailler, être recruté, « je suis livreur ») ou le remercier → social.',
  '- annuler : annuler TOUTE la commande. Retirer ou changer UN article (« enlève le jus », « annule la fanta », « pas de frites ») → designe.',
  '- Un message court qui répond à la question précédente de Tovo s’interprète avec elle (un quartier après « Où récupérer le colis ? » → livreur).',
  '- Fautes, français parlé, transcriptions vocales approximatives, haoussa et zarma : comprends le sens.',
  '',
  'Exemples :',
  '« Je suis coursier, vous recrutez ? » → social',
  '« Apporte-moi des brochettes » → recherche',
  '« un sac de sucre de 50 kg » → recherche',
  '« Le coursier ne décroche pas » → suivi',
  '« J’ai un sac à faire déposer à Gamkalley » → colis',
  '« Retire la fanta » → designe',
  '« Viens me voir, j’ai une course » → livreur',
  '',
  '« sur » : false si la phrase peut raisonnablement vouloir dire autre chose, surtout si l’une des lectures est une action (livreur, colis, annuler, habitude).',
  'Réponds uniquement en JSON : {"intention": "<clé>", "sur": true|false}.',
].join('\n');

export interface ContexteCerveau {
  /** Le dernier message de Tovo : ce à quoi le client répond peut-être. */
  avant?: string | null;
}

export interface DecisionCerveau {
  intention: Intention | null;
  sur: boolean;
  /** Le modèle qui a répondu le premier, ou null. */
  modele: string | null;
  ms: number;
  /** Un second modèle a-t-il été lancé ? */
  relance: boolean;
  erreurs: string[];
}

export type Essai = (message: string, signal: AbortSignal) => Promise<{ intention: Intention; sur: boolean }>;

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    intention: { type: 'STRING', enum: Object.keys(INTENTIONS) },
    sur: { type: 'BOOLEAN' },
  },
  required: ['intention', 'sur'],
};

export function lireDecision(texte: string): { intention: Intention; sur: boolean } | null {
  const brut = texte.match(/\{[\s\S]*\}/)?.[0];
  if (!brut) return null;
  try {
    const v = JSON.parse(brut) as { intention?: string; sur?: unknown };
    if (!v.intention || !(v.intention in INTENTIONS)) return null;
    return { intention: v.intention as Intention, sur: v.sur !== false };
  } catch {
    return null;
  }
}

/** Le texte envoyé au modèle : le message, et ce à quoi il répond. */
export function messagePourCerveau(message: string, contexte: ContexteCerveau = {}): string {
  const avant = contexte.avant?.replace(/\s+/g, ' ').trim().slice(0, 300);
  return avant ? `Dernier message de Tovo : « ${avant} »\nMessage du client : « ${message} »` : message;
}

/**
 * Réflexion interne du modèle. « aucune » : réponse directe (budget 0) —
 * mesuré le 26/09, Flash-Lite 3.1 répond alors en ~0,8 s au lieu de 1,2 s.
 * La réflexion compte dans les jetons de sortie : trop courts, elle coupait
 * la réponse (« MAX_TOKENS », JSON illisible).
 */
export type Reflexion = 'aucune' | 'courte' | 'low';

function reglageReflexion(r: Reflexion): Record<string, unknown> {
  if (r === 'aucune') return { thinkingBudget: 0 };
  if (r === 'courte') return { thinkingBudget: 128 };
  return { thinkingLevel: 'low' };
}

export function essaiGemini(modele: string, reflexion: Reflexion = 'low'): Essai {
  return async (message, signal) => {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY! },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: CONSIGNE_CERVEAU }] },
        contents: [{ role: 'user', parts: [{ text: message }] }],
        generationConfig: {
          maxOutputTokens: 1024,
          responseMimeType: 'application/json',
          responseSchema: SCHEMA,
          thinkingConfig: reglageReflexion(reflexion),
        },
      }),
      signal,
      ...viaLigneGoogle,
    });
    const corps = (await r.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
      error?: { message?: string };
    };
    if (!r.ok) throw new Error(`${modele} ${r.status} ${corps.error?.message?.slice(0, 120) ?? ''}`);
    const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
    const d = lireDecision(texte);
    if (!d) throw new Error(`${modele} : réponse illisible`);
    return d;
  };
}

function openai(modele: string): Essai {
  return async (message, signal) => {
    const raisonne = /^(gpt-5|o\d)/.test(modele);
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY}` },
      body: JSON.stringify({
        model: modele,
        messages: [{ role: 'system', content: CONSIGNE_CERVEAU }, { role: 'user', content: message }],
        response_format: { type: 'json_object' },
        ...(raisonne
          ? { reasoning_effort: /^gpt-5(\.1)?(-|$)/.test(modele) ? 'minimal' : 'none' }
          : { temperature: 0 }),
      }),
      signal,
    });
    const corps = (await r.json()) as { choices?: Array<{ message?: { content?: string } }>; error?: { message?: string } };
    if (!r.ok) throw new Error(`${modele} ${r.status} ${corps.error?.message?.slice(0, 120) ?? ''}`);
    const d = lireDecision(corps.choices?.[0]?.message?.content ?? '');
    if (!d) throw new Error(`${modele} : réponse illisible`);
    return d;
  };
}

/** « gemini-3.1-flash-lite:aucune » → le modèle et sa réflexion. */
export function lireReglage(reglage: string): [string, Reflexion] {
  const [modele, reflexion] = reglage.split(':');
  const r = reflexion === 'aucune' || reflexion === 'courte' ? reflexion : 'low';
  return [modele!, r];
}

export const cerveauActif = (): boolean => env.AIGUILLAGE === 'cerveau' && Boolean(env.GEMINI_API_KEY);

/** Les modèles dans l'ordre : le principal, la relance, le dernier recours. */
function essais(): Array<[string, Essai]> {
  const liste: Array<[string, Essai]> = [];
  if (env.GEMINI_API_KEY) {
    for (const reglage of new Set([env.CERVEAU_MODELE, env.CERVEAU_RELANCE_MODELE])) {
      const [modele, reflexion] = lireReglage(reglage);
      liste.push([modele, essaiGemini(modele, reflexion)]);
    }
  }
  if (env.OPENAI_API_KEY && env.CERVEAU_SECOURS_OPENAI) {
    liste.push([env.CERVEAU_SECOURS_OPENAI, openai(env.CERVEAU_SECOURS_OPENAI)]);
  }
  return liste;
}

export interface OptionsCerveau {
  relanceMs?: number;
  delaiMaxMs?: number;
  /** Pour les tests : remplace les vrais modèles. */
  essais?: Array<[string, Essai]>;
}

export async function comprendre(
  message: string,
  contexte: ContexteCerveau = {},
  options: OptionsCerveau = {},
): Promise<DecisionCerveau> {
  const debut = performance.now();
  const liste = options.essais ?? essais();
  const relanceMs = options.relanceMs ?? env.CERVEAU_RELANCE_MS;
  const delaiMaxMs = options.delaiMaxMs ?? env.CERVEAU_DELAI_MAX_MS;
  const texte = messagePourCerveau(message, contexte);
  const erreurs: string[] = [];
  const controleur = new AbortController();
  const vide = (): DecisionCerveau => ({
    intention: null, sur: false, modele: null, ms: performance.now() - debut, relance: lances > 1, erreurs,
  });
  let lances = 0;
  if (liste.length === 0 || !message.trim()) return vide();

  return new Promise<DecisionCerveau>((resoudre) => {
    let fini = false;
    let enCours = 0;
    let minuterie: ReturnType<typeof setTimeout> | undefined;
    const terminer = (d: DecisionCerveau) => {
      if (fini) return;
      fini = true;
      clearTimeout(minuterie);
      clearTimeout(plafond);
      controleur.abort();
      resoudre(d);
    };
    const plafond = setTimeout(() => {
      erreurs.push(`aucune réponse en ${delaiMaxMs} ms`);
      terminer(vide());
    }, delaiMaxMs);

    const lancerSuivant = () => {
      if (fini) return;
      clearTimeout(minuterie);
      const suivant = liste[lances];
      if (!suivant) {
        if (enCours === 0) terminer(vide());
        return;
      }
      lances++;
      enCours++;
      const [modele, essai] = suivant;
      // Le suivant part à son tour si celui-ci traîne.
      minuterie = setTimeout(lancerSuivant, relanceMs);
      essai(texte, controleur.signal).then(
        (d) => terminer({ ...d, modele, ms: performance.now() - debut, relance: lances > 1, erreurs }),
        (cause: unknown) => {
          enCours--;
          if (fini) return;
          erreurs.push((cause as Error)?.message?.slice(0, 160) ?? String(cause));
          // En panne : inutile d'attendre la minuterie.
          lancerSuivant();
        },
      );
    };
    lancerSuivant();
  });
}
