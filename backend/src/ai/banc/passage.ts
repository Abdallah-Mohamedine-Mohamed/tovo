import { env } from '../../config/env.js';
import { serviceClient } from '../../services/supabase.js';
import { COUTEUSES, comprendre } from '../decideur.js';
import { LIBELLES } from '../aiguillage.js';
import type { Intention } from '../jev.js';
import type { Etiquette } from './guide.js';
import { JEU } from './jeu.js';
import { toutLire } from './lire.js';
import { ecrivain, juge } from './modelesForts.js';
import { SCENARIOS, cleDe, ecrirePhrases, etiqueterALAveugle, memeSens, scenariosDuPassage } from './boucle.js';

/**
 * UN passage de la boucle du banc IA. Lancé par le serveur lui-même
 * (services/bancIa.ts, toutes les 30 minutes par défaut, réglable dans
 * l'admin) ou à la main (npm run banc:boucle).
 *
 * 1. RÉCOLTE : les vraies phrases des clients depuis le passage précédent. Le
 *    juge (modèle fort) les étiquette ; d'accord avec le cerveau → dans
 *    l'examen ; en désaccord → « à trancher » (admin, Qualité de l'IA).
 * 2. ÉCRITURE : un modèle fort imite des clients sur les scénarios du passage ;
 *    un second, d'une autre famille, étiquette à l'aveugle ; seul l'accord
 *    des deux entre dans l'examen.
 * 3. EXAMEN : le cerveau passe l'examen (vraies phrases, pièges, et un
 *    échantillon des phrases écrites) ; le rapport est gardé (banc_passages).
 *
 * Le cerveau n'est jamais modifié ici : la boucle mesure et nourrit l'examen.
 */

export interface OptionsPassage {
  /** Rien n'est écrit en base (essai). */
  sec?: boolean;
  /** Phrases à faire écrire. */
  phrases?: number;
  scenarios?: number;
  /** Phrases écrites tirées au hasard pour l'examen. */
  echantillon?: number;
  /** Récolter N jours en arrière au lieu de « depuis le passage précédent ». */
  jours?: number;
  /**
   * Faire passer l'examen complet à l'assistant (par défaut oui). La boucle
   * ne le fait qu'une fois par heure : il interroge l'assistant avec la même
   * clé Gemini que les clients.
   */
  examiner?: boolean;
  journal?: (message: string) => void;
}

export interface CasNouveau {
  texte: string; avant: string | null; attendu: string; origine: 'reel' | 'synthetique';
  statut: 'valide' | 'a_valider'; etiqueteur: string | null; juge: string | null; cerveau: string | null;
  note: string | null; cle: string;
}

/** Par petits paquets, quelques-uns à la fois. */
async function parPaquets<T, R>(liste: T[], taille: number, enParallele: number, f: (paquet: T[]) => Promise<R[]>): Promise<R[]> {
  const paquets: T[][] = [];
  for (let i = 0; i < liste.length; i += taille) paquets.push(liste.slice(i, i + taille));
  const sorties: R[][] = new Array(paquets.length);
  let suivant = 0;
  await Promise.all(Array.from({ length: enParallele }, async () => {
    for (let i = suivant++; i < paquets.length; i = suivant++) sorties[i] = await f(paquets[i]!);
  }));
  return sorties.flat();
}

const auHasard = <T>(l: T[], n: number) => [...l].sort(() => Math.random() - 0.5).slice(0, n);

export async function passageDuBanc(options: OptionsPassage = {}) {
  const sec = options.sec ?? false;
  const phrasesVoulues = options.phrases ?? 30;
  const nbScenarios = Math.min(SCENARIOS.length, options.scenarios ?? 2);
  const echantillon = options.echantillon ?? 600;
  const debut = Date.now();
  const journal = (m: string) => options.journal?.(`[${Math.round((Date.now() - debut) / 1000)} s] ${m}`);
  const db = serviceClient();
  const leJuge = juge();
  const lEcrivain = ecrivain();

  /** Le juge, par paquets de 40 ; une panne rend « inconnu » plutôt que d'arrêter le passage. */
  const juger = (phrases: Array<{ texte: string; avant?: string | null }>) =>
    parPaquets(phrases, 40, 3, async (paquet): Promise<Array<Etiquette | null>> => {
      try {
        return await etiqueterALAveugle(leJuge, paquet);
      } catch (cause) {
        journal(`juge en panne sur un paquet : ${(cause as Error).message.slice(0, 120)}`);
        return paquet.map(() => null);
      }
    });

  /**
   * Ce que le cerveau comprend (« tuiles » s'il hésite sur une action), et
   * s'il doute : une phrase ambiguë ou erronée doit le faire douter.
   */
  const lireAvecDoute = (cas: Array<{ texte: string; avant?: string | null }>) =>
    parPaquets(cas, 1, 5, async ([c]): Promise<Array<{ predit: Intention | 'tuiles' | null; doute: boolean }>> => {
      const d = await comprendre(c!.texte, { avant: c!.avant ?? null });
      if (!d.intention) return [{ predit: null, doute: false }];
      return [{ predit: !d.sur && COUTEUSES.has(d.intention) ? 'tuiles' : d.intention, doute: !d.sur }];
    });
  const cerveau = async (cas: Array<{ texte: string; avant?: string | null }>) =>
    (await lireAvecDoute(cas)).map((r) => r.predit);

  // ── Ce que l'examen contient déjà ─────────────────────────────────────
  const connues = new Set(JEU.map((c) => cleDe(c.texte, c.avant)));
  if (!sec) {
    for (let page = 0; page < 100; page++) {
      const { data, error } = await db.from('banc_cas').select('cle').range(page * 1000, page * 1000 + 999);
      if (error) throw new Error(`table banc_cas illisible (migration 0065 appliquée ?) : ${error.message}`);
      for (const l of data ?? []) connues.add(l.cle as string);
      if ((data ?? []).length < 1000) break;
    }
  }
  journal(`${connues.size} phrases déjà dans l'examen`);
  const nouveaux: CasNouveau[] = [];

  // ── 1. Récolte des vraies phrases ─────────────────────────────────────
  let depuis = new Date(Date.now() - (options.jours ?? 1) * 86_400_000).toISOString();
  if (!sec && options.jours === undefined) {
    const { data: dernier } = await db.from('banc_passages').select('cree_le').order('cree_le', { ascending: false }).limit(1);
    const le = dernier?.[0]?.cree_le as string | undefined;
    // Un peu de recouvrement : une phrase à cheval n'est pas perdue (les
    // doublons sont écartés par leur clé).
    if (le) depuis = new Date(Date.parse(le) - 5 * 60_000).toISOString();
  }
  const { data: messages, error: erreurMessages } = await toutLire((de, a) => db.from('messages')
    .select('id, conversation_id, role, content, created_at')
    .in('role', ['user', 'assistant']).gte('created_at', depuis)
    .order('created_at', { ascending: true }).order('id').range(de, a), 20_000);
  if (erreurMessages) throw erreurMessages;
  const tuiles = new Set([...Object.values(LIBELLES), 'Autre chose', 'Oui, annuler', 'Non, la garder'].map((t) => cleDe(t)));
  const technique = /^(📷|🎤|J'ai envoyé une photo|L'utilisateur a parlé|Action :|Recommander ma commande|Commander)/;
  const reels = new Map<string, { texte: string; avant: string | null; autreChose: boolean }>();
  const lignes = (messages ?? []) as Array<{ conversation_id: string; role: string; content: string | null }>;
  for (let i = 0; i < lignes.length; i++) {
    const m = lignes[i]!;
    const texte = (m.content ?? '').trim();
    if (m.role !== 'user' || !texte || texte.length > 300 || technique.test(texte)) continue;
    const precedent = lignes.slice(0, i).reverse().find((l) => l.conversation_id === m.conversation_id);
    const avant = precedent?.role === 'assistant' ? (precedent.content ?? '').slice(0, 300) || null : null;
    const cle = cleDe(texte, avant);
    if (connues.has(cle) || tuiles.has(cleDe(texte)) || reels.has(cle)) continue;
    const suivant = lignes.slice(i + 1).find((l) => l.conversation_id === m.conversation_id && l.role === 'user');
    reels.set(cle, { texte, avant, autreChose: suivant?.content?.trim() === 'Autre chose' });
  }
  const listeReels = [...reels.entries()];
  journal(`${listeReels.length} vraies phrases nouvelles`);
  const [jugesReels, cerveauReels] = await Promise.all([
    juger(listeReels.map(([, r]) => r)),
    cerveau(listeReels.map(([, r]) => r)),
  ]);
  listeReels.forEach(([cle, r], i) => {
    const j = jugesReels[i] ?? null;
    const c = cerveauReels[i] ?? null;
    if (!j) return;
    const daccord = c !== 'tuiles' && memeSens(j, c as Etiquette | null) && !r.autreChose;
    nouveaux.push({
      texte: r.texte, avant: r.avant, attendu: j === 'ambigu' ? (c ?? 'social') : j, origine: 'reel',
      statut: daccord ? 'valide' : 'a_valider', etiqueteur: j, juge: j, cerveau: c,
      note: r.autreChose ? 'Le client a touché « Autre chose » après ce message.' : null, cle,
    });
    connues.add(cle);
  });

  // ── 2. Écriture de phrases synthétiques ───────────────────────────────
  let ecrites: Array<{ texte: string; intention: Intention; avant?: string | null; note?: string; scenario: string }> = [];
  let ecartees = 0;
  const failles: Array<{ texte: string; avant: string | null; attendu: string; cerveau: string | null; scenario: string }> = [];
  const scenarios = scenariosDuPassage(new Date(), nbScenarios);
  if (phrasesVoulues > 0) {
    const { data: boutiques } = await db.from('merchants').select('name').eq('is_approved', true).limit(300);
    const { data: produits } = await db.from('products').select('name').eq('is_available', true).limit(3000);
    const contexte = {
      boutiques: auHasard((boutiques ?? []).map((b) => String(b.name)), 25),
      produits: auHasard((produits ?? []).map((p) => String(p.name)), 60),
      quartiers: ['Yantala', 'Plateau', 'Harobanda', 'Francophonie', 'Koira Kano', 'Lazaret', 'Niamey 2000', 'Talladjé', 'Gamkalley', 'Bobiel', 'Kalley', 'Dar es Salam', 'Recasement', 'Aéroport', 'Banifandou', 'Wadata'],
      dejaVues: auHasard(JEU.map((c) => c.texte), 40),
    };
    const parScenario = Math.ceil(phrasesVoulues / scenarios.length);
    // Des lots de 30 au plus : au-delà, une seule réponse devient très longue
    // et le modèle se répète.
    const lots = scenarios.flatMap((sc) => Array.from(
      { length: Math.ceil(parScenario / 30) },
      (_, i) => ({ scenario: sc, combien: Math.min(30, parScenario - i * 30) }),
    ));
    journal(`écriture : ${scenarios.map((sc) => sc.cle).join(', ')} (${parScenario} phrases chacun, ${lots.length} lots)`);
    ecrites = (await parPaquets(lots, 1, 4, async ([lot]) => {
      try {
        return (await ecrirePhrases(lEcrivain, lot!.scenario, lot!.combien, contexte)).map((p) => ({ ...p, scenario: lot!.scenario.cle }));
      } catch (cause) {
        journal(`écrivain en panne sur « ${lot!.scenario.cle} » : ${(cause as Error).message.slice(0, 120)}`);
        return [];
      }
    })).filter((p) => {
      const cle = cleDe(p.texte, p.avant);
      if (connues.has(cle)) return false;
      connues.add(cle);
      return true;
    });
    journal(`${ecrites.length} phrases écrites, jugement à l'aveugle…`);
    const [jugesEcrites, cerveauEcrites] = await Promise.all([juger(ecrites), cerveau(ecrites)]);
    ecrites.forEach((p, i) => {
      const j = jugesEcrites[i] ?? null;
      const c = cerveauEcrites[i] ?? null;
      if (!memeSens(p.intention, j)) {
        // Les deux modèles forts ne sont pas d'accord : souvent la phrase la
        // plus intéressante (ambiguë, ou une intention qui manque). Elle part
        // à l'humain au lieu d'être jetée (demande du client, 26/09).
        ecartees++;
        if (j) {
          nouveaux.push({
            texte: p.texte, avant: p.avant ?? null, attendu: p.intention, origine: 'synthetique', statut: 'a_valider',
            etiqueteur: p.intention, juge: j, cerveau: c,
            note: `[${p.scenario}] Les deux IA ne sont pas d'accord. ${p.note ?? ''}`.trim(), cle: cleDe(p.texte, p.avant),
          });
        }
        return;
      }
      if (c !== 'tuiles' && !memeSens(p.intention, c as Etiquette | null)) {
        failles.push({ texte: p.texte, avant: p.avant ?? null, attendu: p.intention, cerveau: c, scenario: p.scenario });
      }
      nouveaux.push({
        texte: p.texte, avant: p.avant ?? null, attendu: p.intention, origine: 'synthetique', statut: 'valide',
        etiqueteur: p.intention, juge: j, cerveau: c, note: `[${p.scenario}] ${p.note ?? ''}`.trim(), cle: cleDe(p.texte, p.avant),
      });
    });
    journal(`${ecrites.length - ecartees} gardées par accord des deux modèles, ${ecartees} écartées`);
  }

  if (!sec && nouveaux.length) {
    for (let i = 0; i < nouveaux.length; i += 500) {
      const { error } = await db.from('banc_cas').upsert(nouveaux.slice(i, i + 500), { onConflict: 'cle', ignoreDuplicates: true });
      if (error) throw error;
    }
  }

  // ── 3. L'examen du cerveau ────────────────────────────────────────────
  // reponse : 'intention' (un sens), 'tuiles' (ambiguë : l'assistant doit
  // douter et proposer des choix), 'erronee' (il ne doit pas agir).
  type CasExamen = { texte: string; avant: string | null; attendu: string; origine: string; reponse?: string; aussi?: string[] };
  const examiner = options.examiner ?? true;
  let examen: CasExamen[] = examiner
    ? JEU.map((c) => ({ texte: c.texte, avant: c.avant ?? null, attendu: c.attendu, origine: c.source, ...(c.aussi ? { aussi: c.aussi } : {}) }))
    : [];
  if (!sec && examiner) {
    let lecture = await toutLire((de, a) => db.from('banc_cas').select('texte, avant, attendu, origine, reponse')
      .eq('statut', 'valide').order('id').range(de, a));
    // Migration 0066 pas encore appliquée : sans la colonne reponse.
    if (lecture.error) {
      lecture = await toutLire((de, a) => db.from('banc_cas').select('texte, avant, attendu, origine')
        .eq('statut', 'valide').order('id').range(de, a)) as typeof lecture;
    }
    const base = lecture.data as unknown as CasExamen[];
    const reelsBase = base.filter((c) => c.origine !== 'synthetique');
    const synth = auHasard(base.filter((c) => c.origine === 'synthetique'), Math.max(0, echantillon - reelsBase.length));
    examen = [...examen, ...reelsBase, ...synth];
  } else if (examiner) {
    examen = [...examen, ...nouveaux.filter((c) => c.statut === 'valide')];
  }
  if (examiner) journal(`examen : ${examen.length} phrases`);
  const lus = await lireAvecDoute(examen);
  const sansSens = (c: CasExamen) => c.reponse === 'tuiles' || c.reponse === 'erronee';
  const juste = (c: CasExamen, i: number) => sansSens(c)
    ? lus[i]!.doute
    : lus[i]!.predit === c.attendu || memeSens(lus[i]!.predit as Etiquette, c.attendu as Etiquette)
      || Boolean(lus[i]!.predit && c.aussi?.includes(lus[i]!.predit!));
  const justes = examen.filter(juste).length;
  const aTort = examen
    .map((c, i) => ({ ...c, predit: lus[i]!.predit, doute: lus[i]!.doute }))
    .filter((c) => c.predit && c.predit !== 'tuiles' && COUTEUSES.has(c.predit as Intention)
      && (sansSens(c) ? !c.doute : !memeSens(c.predit as Etiquette, c.attendu as Etiquette))
      && !c.aussi?.includes(c.predit));
  const ambigues = examen.filter(sansSens);

  const rapport = {
    passage: new Date().toISOString(),
    depuis,
    duree_s: Math.round((Date.now() - debut) / 1000),
    modeles: { cerveau: env.CERVEAU_MODELE, ecrivain: lEcrivain.nom, juge: leJuge.nom },
    reels: {
      recoltees: listeReels.length,
      dans_examen: nouveaux.filter((c) => c.origine === 'reel' && c.statut === 'valide').length,
      a_valider: nouveaux.filter((c) => c.origine === 'reel' && c.statut === 'a_valider').length,
    },
    synthetiques: { scenarios: scenarios.map((s) => s.cle), ecrites: ecrites.length, gardees: ecrites.length - ecartees, ecartees },
    examen: examiner ? {
      phrases: examen.length,
      justesse: examen.length ? Math.round((1000 * justes) / examen.length) / 10 : null,
      actions_couteuses_a_tort: aTort.length,
      exemples_a_tort: aTort.slice(0, 15).map((c) => ({ texte: c.texte, attendu: c.reponse === 'intention' || !c.reponse ? c.attendu : c.reponse, predit: c.predit })),
      // Ambiguës et erronées : l'assistant a-t-il douté, au lieu de deviner ?
      ambigues: { phrases: ambigues.length, doutes: ambigues.filter((c) => lus[examen.indexOf(c)]!.doute).length },
    } : null,
    nouvelles_failles: failles.slice(0, 40),
  };
  if (!sec) {
    const ecrit = await db.from('banc_passages').insert({ rapport, examine: examiner });
    // Migration 0066 pas encore appliquée : sans la colonne examine.
    if (ecrit.error) await db.from('banc_passages').insert({ rapport });
  }
  return { rapport, nouveaux, failles };
}
