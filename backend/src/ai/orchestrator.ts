import type { SupabaseClient } from '@supabase/supabase-js';
import { llmClient, LlmUnavailableError, type LlmTurn } from './llmClient.js';
import { SYSTEM_PROMPT, contexteUtilisateur } from './systemPrompt.js';
import { EXECUTORS, TOOL_DEFINITIONS, type ToolContext } from './tools.js';
import { collectIds, sanitizeToolResult, validateComponents } from './validate.js';
import { envelope, merchantCard, type ChatEnvelope, type Component } from '../components/builders.js';
import { cataloguePage, horsTovo, resolveCatalogueIntent, merchantIntentAnswer, searchAnswer, type CataloguePage, type PendingMerchantChoice } from '../services/catalogue.js';
import {
  demandeBoutiqueOuverte,
  demandeDeCommandePassee,
  demandeOuverte,
  messageConversationnel,
  normaliserIntention,
  nomBoutiqueApresMarqueur,
  referenceAuxResultats,
  requeteProduitUtilisateur,
} from './intents.js';
import { resumeAffichage } from './memoire.js';
import type { Intention } from './jev.js';
import type { Rayon } from './decideur.js';
import { idDuRayon } from '../services/catalogue.js';
import { avecOuvertureReelle } from '../services/ouverture.js';
import { Faits, FluxVerifie, verifierTexte, type Verification } from './verificateur.js';
import { rediger, redigerEtJuger, sansPromesseVide } from './redacteur.js';

/**
 * Boucle d'orchestration.
 *
 * Le modèle ne rédige jamais l'interface : il choisit des outils, les outils
 * produisent les composants. Sa contribution est le texte qui les accompagne
 * et l'enchaînement des appels.
 *
 * Deux garde-fous encadrent la boucle :
 *
 *   MAX_CYCLES — un modèle peut boucler sur un outil qui ne lui donne pas ce
 *   qu'il attend. Au troisième tour, on lui retire les outils et on exige une
 *   réponse. Mieux vaut une phrase imparfaite qu'un client qui attend.
 *
 *   validate.ts — tout identifiant qu'un composant cite doit provenir d'un
 *   outil de CE tour. C'est le seul endroit qui rend vraie la promesse « l'IA
 *   n'invente rien ».
 */

const MAX_CYCLES = 3;
const HISTORIQUE = 10;

export interface OrchestrateInput {
  db: SupabaseClient;
  userId: string;
  conversationId: string;
  /** Texte de l'utilisateur, ou description de l'interaction. */
  message: string;
  /** Généré par Flutter avant l'envoi : c'est la clé d'idempotence. */
  clientMessageId: string;
  /**
   * Ce que le CLIENT doit relire dans son historique.
   *
   * `message` est une consigne écrite pour le modèle — « L'utilisateur a
   * parlé. Écoute l'enregistrement… », ou un chemin de fichier de 60
   * caractères. C'était pourtant lui qu'on enregistrait, et donc lui qui
   * réapparaissait dans la conversation à sa réouverture, dans une bulle
   * verte censée être la parole du client.
   *
   * Absent, on retombe sur `message` : pour un message tapé, les deux sont
   * la même chose.
   */
  messagePublic?: string | undefined;
  /**
   * Message vocal, transmis au modèle et jamais conservé.
   *
   * Contrairement à la photo de recherche, qui transite par Storage et peut
   * resservir, la voix d'un client est une donnée personnelle sans usage
   * ultérieur : elle traverse la requête et disparaît avec elle.
   */
  audio?: { mime: string; data: string } | undefined;
  position?: { lat: number; lng: number } | undefined;
  onEvent?: ((event: Record<string, unknown>) => void) | undefined;
  /**
   * Route déjà connue (Jev, ou tuile touchée par le client). Hors catalogue
   * (suivi, annulation, habitude…), les voies rapides par mots ne tournent
   * pas : elles transformaient « ça fait une heure que j'attends » en
   * recherche de produit. `modele` : le modèle décide seul.
   */
  intention?: Intention | 'modele' | undefined;
  /**
   * Ce que le client cherche, extrait par le cerveau (« merguez »). Préféré au
   * découpage à mots du message, qui ne comprend pas la phrase.
   */
  requete?: string | undefined;
  /** Le rayon où chercher, selon le cerveau : la recherche y reste. */
  rayon?: Rayon | undefined;
  /**
   * Recherche lexicale déjà faite par la route, en parallèle de Jev, sur le
   * MÊME message : on ne la refait pas.
   */
  pageInitiale?: CataloguePage | undefined;
}

export interface OrchestrateOutput extends ChatEnvelope {
  messageId: string | null;
  /** Rejets du validateur — un pic signale un prompt qui dérive. */
  rejected: string[];
  /**
   * Phrases retirées par le vérificateur : elles affirmaient un prix, une
   * durée ou un nom qui ne venait pas de la base. Journalisées, et récoltées
   * pour le banc.
   */
  inventions?: Verification['retirees'];
  usage: { input: number; output: number; cached: number; cycles: number };
}

export class ChatUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ChatUnavailableError';
  }
}

/** Les boutiques ouvertes en ce moment, les mieux notées d'abord. */
async function boutiquesOuvertes(db: SupabaseClient): Promise<{ components: Component[]; summary: unknown }> {
  const { data } = await db
    .from('merchants')
    .select('id, name, description, logo_url, address_hint, is_open, rating, prep_time_min')
    .eq('is_approved', true)
    .eq('is_open', true)
    .order('rating', { ascending: false })
    .limit(40);
  const brutes = ((data ?? []) as Record<string, unknown>[]).map((m) => ({
    id: m['id'] as string,
    name: m['name'] as string,
    description: (m['description'] as string | null) ?? null,
    logo_url: (m['logo_url'] as string | null) ?? null,
    address_hint: (m['address_hint'] as string | null) ?? '',
    is_open: true,
    rating: Number(m['rating'] ?? 5),
    prep_time_min: (m['prep_time_min'] as number) ?? 20,
    distance_m: null,
  }));
  // Interrupteur ET horaires : on en lit plus, on n'en garde que les
  // vraiment ouvertes.
  const boutiques = (await avecOuvertureReelle(db, brutes)).filter((b) => b.is_open).slice(0, 8);
  return {
    components: boutiques.map(merchantCard),
    summary: { boutiques: boutiques.map((b) => ({ id: b.id, nom: b.name })) },
  };
}

/**
 * Les outils d'ACTION que l'assistant ne reçoit que si le cerveau a compris
 * cette action (02/10, principe « un seul interprète », docs/PARCOURS-
 * CLIENTS.md). Le cerveau disait « recherche » pour « un colis de riz de
 * 25 kg » ; l'assistant, relisant la phrase brute, voyait « colis » et
 * ouvrait la carte de course (3 fois sur 4 sous charge). Sans décision du
 * cerveau (panne, tuile « Autre chose », bouton), l'assistant garde tout.
 */
const OUTILS_D_ACTION: Record<string, ReadonlyArray<Intention | 'modele'>> = {
  preparer_course: ['livreur', 'colis', 'modele'],
  annuler_commande: ['annuler', 'aide', 'modele'],
  recommander_commande: ['habitude', 'designe', 'modele'],
};
export function outilsPermis(intention: Intention | 'modele' | undefined): typeof TOOL_DEFINITIONS {
  if (!intention) return TOOL_DEFINITIONS;
  return TOOL_DEFINITIONS.filter((t) => !OUTILS_D_ACTION[t.name] || OUTILS_D_ACTION[t.name]!.includes(intention));
}

export function rechercheProduitRapide(message: string, query: string): boolean {
  const mots = query.split(/\s+/).filter(Boolean);
  const questionCourte = /^(avez vous|as tu|il y a|y a t il|un|une|du|de la|des)\b/
    .test(normaliserIntention(message));
  return query.length > 0
    && !messageConversationnel(message)
    && !demandeOuverte(query)
    && !demandeBoutiqueOuverte(message)
    && (mots.length <= 6 || questionCourte)
    && !/\b(merci|bonjour|salut|oui|non|annule|commande|livreur|colis|panier|option|options|deuxieme|premier)\b/i.test(message);
}

export async function orchestrate(input: OrchestrateInput): Promise<OrchestrateOutput> {
  const historique = chargerHistorique(input.db, input.conversationId);
  // « Le deuxième », « ajoute-le » : le client désigne ce qu'il a déjà vu. Ces
  // phrases ne contiennent aucun produit ; les passer aux voies rapides les
  // transformait en recherche du mot « ajoute », qui répondait « introuvable ».
  const reference = !input.audio && referenceAuxResultats(input.message);
  // « Comme d'habitude » : aucun produit dans la phrase, seul le modèle sait
  // relire l'historique des commandes. Toujours au modèle, affichage ou pas.
  const commandePassee = !input.audio && demandeDeCommandePassee(input.message);
  // « De la viande chez Tchos » : la boutique nommée décide. Le produit et le
  // rayon du cerveau (« viande Tchos », repas) ramenaient Maison Grill.
  const boutiqueNommee = !input.audio && Boolean(nomBoutiqueApresMarqueur(input.message));
  const requeteInitiale = input.audio ? ''
    : requeteProduitUtilisateur((boutiqueNommee ? undefined : input.requete) ?? input.message);
  // Recherche ou boutique : le catalogue a son mot à dire. Toute autre route
  // connue va droit au modèle.
  const catalogueAutorise = !input.intention || input.intention === 'recherche' || input.intention === 'boutique';
  // Le rayon compris par le cerveau : la recherche y reste (« huile » →
  // supermarché, jamais les huiles d'argan de la beauté).
  const rayonId = input.rayon && !input.audio && !boutiqueNommee ? await idDuRayon(input.db, input.rayon) : undefined;
  // Le cerveau a compris une recherche et dit quoi chercher : le filtre à
  // mots ne la refuse plus. « un colis de riz » contient « colis », et
  // partait à l'assistant alors que le cerveau disait « riz » (02/10).
  const rechercheDuCerveau = (input.intention === 'recherche' || input.intention === 'boutique') && Boolean(input.requete);
  const rapide = (requete: string) => requete.length > 0
    && (rechercheDuCerveau || rechercheProduitRapide(input.message, requete));
  const rechercheInitiale = input.pageInitiale
    ? Promise.resolve(input.pageInitiale)
    : !input.audio && !reference && !commandePassee && catalogueAutorise
    && rapide(requeteInitiale)
    // Premier passage lexical uniquement : il doit rester plus rapide qu'un
    // appel modèle. Les fautes et rapprochements sémantiques restent pris en
    // charge par le chemin complet juste après.
    ? cataloguePage(input.db, { q: requeteInitiale, limit: 8, category_id: rayonId }, false)
    : Promise.resolve(null);
  const [previous, pageInitiale] = await Promise.all([historique, rechercheInitiale]);

  // Une référence ne vaut que s'il y a quelque chose à désigner. Sinon, le
  // message suit le chemin normal (« le moins cher » tout court reste une
  // recherche).
  //
  // Exception : un choix d'agence en attente (« Otakoss » → Centre aéré ou
  // Nouveau Marché ?). « Le premier » y est déjà résolu sans modèle par
  // resolveCatalogueIntent, instantanément et sans risque d'erreur : on lui
  // laisse la main.
  const versModele = commandePassee || (reference && previous.affichage && !previous.pending)
    // Route hors catalogue connue. Exception : un choix d'agence en attente
    // (« le premier ») reste résolu sans modèle, comme plus haut.
    || (!catalogueAutorise && !(input.intention === 'designe' && previous.pending));

  // Le rédacteur (ai/redacteur.ts) : toute réponse rapide est mise en mots
  // par une IA, à partir du message EXACT du client. Les cartes partent
  // d'abord ; la phrase suit, ~0,5–1 s plus tard.
  const dernierDeTovo = [...previous.history].reverse().find((t) => t.role === 'model')?.content ?? null;
  const enMots = (prevue: string, faits: unknown, composants: Component[]) => (input.audio
    ? Promise.resolve(prevue)
    : rediger({ message: input.messagePublic ?? input.message, prevue, faits, composants, avant: dernierDeTovo }));
  // Des produits trouvés : le rédacteur dit aussi s'ils répondent vraiment à
  // la demande (« deux litres de lait » ramenait des savons au lait). Sinon,
  // les commerces hors Tovo qui en ont probablement.
  const produitsOuAilleurs = async (reponse: { content: string; summary: Record<string, unknown>; components: Component[] }) => {
    const produits = reponse.components.some((c) => c.type === 'product_carousel' || c.type === 'product_list');
    if (!produits || input.audio) return { reponse, phrase: await enMots(reponse.content, reponse.summary, reponse.components) };
    const j = await redigerEtJuger({ message: input.messagePublic ?? input.message, prevue: reponse.content,
      faits: reponse.summary, composants: reponse.components, avant: dernierDeTovo });
    if (j.pertinent === false) {
      const ailleurs = await horsTovo(input.db, input.message, input.requete ?? requeteInitiale, input.position);
      if (ailleurs) return { reponse: ailleurs, phrase: await enMots(ailleurs.content, ailleurs.summary, ailleurs.components) };
    }
    return { reponse, phrase: j.texte };
  };

  const photoRecente = previous.history.slice(-4).some((turn) =>
    turn.role === 'user' && /photo envoyee/i.test(normaliserIntention(turn.content)));
  const correctionPhoto = !versModele && photoRecente
    && /^(?:mais )?(?:c est|ce sont) (?:un |une |des )?/i.test(normaliserIntention(input.message));
  if (correctionPhoto && requeteInitiale) {
    const page = pageInitiale ?? await cataloguePage(input.db, { q: requeteInitiale, limit: 8 }, false);
    const mots = requeteInitiale.split(' ');
    const items = page.items.filter((item) => {
      const fiche = normaliserIntention(`${item.name} ${item.description ?? ''}`);
      return mots.every((mot) => fiche.split(' ').includes(mot));
    });
    const answer = searchAnswer({ ...page, items, total: items.length, next_offset: null },
      { q: requeteInitiale, limit: 8 });
    const content = items.length > 0
      ? `Vous avez raison, j’ai mal interprété la photo. Voici des ${requeteInitiale} correspondant au catalogue.`
      : `Vous avez raison, j’ai mal interprété la photo. Je ne trouve pas de ${requeteInitiale} correspondant dans le catalogue actuellement.`;
    input.onEvent?.({ type: 'results', components: answer.components });
    const phrase = await enMots(content, answer.summary, answer.components);
    input.onEvent?.({ type: 'text', text: phrase });
    const messageId = await persister(input, phrase, answer.components);
    return { ...envelope(phrase, answer.components), messageId, rejected: [],
      usage: { input: 0, output: 0, cached: 0, cycles: 0 } };
  }

  // Le produit est déjà trouvé : inutile de charger toutes les enseignes,
  // puis de refaire exactement la même recherche. C'est le chemin courant.
  // Seulement un résultat EXACT (ou une catégorie) : une « suggestion
  // proche » ne doit pas couper court à la reconnaissance d'une boutique.
  // « Garbador » (Garba d'Or dit à voix haute) trouvait « Garba » en
  // suggestion, et la carte de la boutique n'était jamais proposée.
  if (pageInitiale && pageInitiale.match_type !== 'similar'
    && (pageInitiale.total > 0 || pageInitiale.category_id)) {
    const { reponse: direct, phrase } = await produitsOuAilleurs(searchAnswer(pageInitiale, { q: requeteInitiale, limit: 8 }));
    input.onEvent?.({ type: 'results', components: direct.components });
    input.onEvent?.({ type: 'text', text: phrase });
    const messageId = await persister(input, phrase, direct.components);
    return { ...envelope(phrase, direct.components), messageId, rejected: [],
      usage: { input: 0, output: 0, cached: 0, cycles: 0 } };
  }

  // Pour une référence, aucune intention de catalogue à résoudre : le modèle
  // retrouve l'élément dans ce qu'il a affiché (voir memoire.ts).
  const intent = input.audio || versModele
    ? undefined
    : await resolveCatalogueIntent(input.db, input.message, previous.pending);
  let direct = intent ? await merchantIntentAnswer(input.db, intent) : null;
  // Ce que le cerveau a compris (« merguez »), sauf quand une boutique est
  // nommée : la requête est alors ce qui reste une fois son nom retiré.
  const requeteClient = input.requete && intent && intent.merchants.length === 0 && !intent.missing
    ? requeteProduitUtilisateur(input.requete)
    : requeteProduitUtilisateur(intent?.query ?? input.message);
  const keyword = rapide(requeteClient);
  const selectedBranch = Boolean(previous.pending
    && intent?.merchants.length === 1
    && intent.query === previous.pending.query);
  if (!direct && intent && (keyword || selectedBranch) && !input.audio) {
    const filter = { q: requeteClient || intent.query, limit: 8,
      merchant_ids: intent.merchants.length ? intent.merchants.map((merchant) => merchant.id) : undefined,
      // Dans une boutique nommée, toute sa carte ; sinon le rayon compris.
      category_id: intent.merchants.length ? undefined : rayonId };
    // Une phrase courte n'est pas forcément un produit. « Tu es bête »
    // partait directement dans la recherche sémantique et remontait des
    // carottes. Le chemin instantané n'est permis que pour une correspondance
    // littérale, une catégorie connue, ou le choix explicite d'une agence.
    const page = pageInitiale && intent.merchants.length === 0 && requeteClient === requeteInitiale
      ? pageInitiale
      : await cataloguePage(input.db, filter, selectedBranch ? true : false);
    // Tovo n'a rien : où le trouver ailleurs (un commerce nommé, Google si le
    // cerveau a compris « boutique », ou les commerces du bon type). La phrase
    // est ensuite réécrite par le rédacteur.
    // Des ressemblances seulement (« pomme » pour « pommade ») : un commerce
    // qui vend vraiment le produit demandé passe devant.
    if ((page.total === 0 || page.match_type === 'similar') && !page.category_id && intent.merchants.length === 0) {
      direct = await horsTovo(input.db, input.message, requeteClient || intent.query, input.position,
        { boutique: input.intention === 'boutique' });
    }
    if (!direct && (page.total > 0 || page.category_id || selectedBranch || keyword)) {
      direct = searchAnswer(page, filter);
    }
  }
  // « Quelles boutiques sont ouvertes ? » : la réponse existe même sans la
  // position du client. Elle était exigée ; sans elle, la question partait
  // au modèle, qui répondait… par la liste des catégories.
  if (!direct && intent && !input.audio
      && intent.merchants.length === 0 && !intent.missing
      && demandeBoutiqueOuverte(input.message)) {
    const ouvertes = input.position
      ? await EXECUTORS.boutiques_proches!({}, {
        db: input.db,
        userId: input.userId,
        currentMessage: input.message,
        catalogueIntent: intent,
        position: input.position,
      })
      : await boutiquesOuvertes(input.db);
    direct = {
      content: ouvertes.components.length > 0
        ? 'Voici les boutiques ouvertes en ce moment.'
        : "Je ne trouve aucune boutique ouverte autour de vous pour le moment.",
      summary: ouvertes.summary as Record<string, unknown>,
      components: ouvertes.components,
    };
  }
  if (direct) {
    const choisi = await produitsOuAilleurs(direct);
    direct = choisi.reponse;
    const phrase = choisi.phrase;
    input.onEvent?.({ type: 'results', components: direct.components });
    input.onEvent?.({ type: 'text', text: phrase });
    const messageId = await persister(input, phrase, direct.components);
    return { ...envelope(phrase, direct.components), messageId, rejected: [],
      usage: { input: 0, output: 0, cached: 0, cycles: 0 } };
  }
  const client = llmClient();
  if (!client) {
    throw new ChatUnavailableError(
      "L'assistant n'est pas disponible pour le moment.",
    );
  }

  const ctx: ToolContext = {
    db: input.db,
    userId: input.userId,
    currentMessage: input.audio ? undefined : input.message,
    ...(input.requete ? { requete: input.requete } : {}),
    ...(rayonId ? { rayonId } : {}),
    catalogueIntent: intent,
    position: input.position,
  };

  const history = previous.history;

  history.push({
    role: 'user',
    content: `${contexteUtilisateur(input.position)}\n\n${input.message}`,
    // L'ENREGISTREMENT LUI-MÊME. Il était reçu par la route, transmis
    // jusqu'ici, déclaré dans l'interface d'entrée — et jamais attaché au
    // tour envoyé au modèle.
    //
    // Gemini ne recevait donc que la consigne « écoute l'enregistrement »,
    // sans enregistrement. N'ayant rien à écouter, il enchaînait sur ce que
    // le contexte rendait plausible : un panier en cours devenait une
    // question sur l'adresse de livraison, quoi qu'ait dit le client.
    //
    // Aucune erreur nulle part : ni exception, ni réponse vide. Juste un
    // modèle qui répond à côté, ce qui est le plus difficile à voir.
    ...(input.audio ? { audio: input.audio } : {}),
  });

  const composantsDuTour: Component[] = [];
  const idsAutorises = new Set<string>();
  // Ce qui est vrai pendant ce tour : la phrase du client, ce qui était déjà
  // à l'écran, puis tout ce que les outils renverront (verificateur.ts).
  const faits = new Faits();
  // Les mots du client : des noms, jamais des montants ni des durées.
  faits.ajouterParole(input.message);
  for (const tour of previous.history) {
    if (tour.role === 'user') faits.ajouterParole(tour.content);
    else faits.ajouter(tour.content);
  }
  const inventions: Verification['retirees'] = [];
  let texteFinal = '';
  let entree = 0;
  let sortie = 0;
  let misEnCache = 0;
  let cycles = 0;

  cyclesOrchestration: for (; cycles < MAX_CYCLES; cycles++) {
    const dernierCycle = cycles === MAX_CYCLES - 1;
    let reponseOutil: string | undefined;
    let resumeOutil: unknown;
    input.onEvent?.({ type: 'text_start' });

    // Au fil de l'eau, mais phrase par phrase : une phrase ne s'affiche que
    // complète et vérifiée.
    const flux = new FluxVerifie(faits, (text) => input.onEvent?.({ type: 'text', text }));
    const reponse = await client.generate({
      system: SYSTEM_PROMPT,
      history,
      // Au dernier cycle, plus d'outils : le modèle doit conclure.
      tools: dernierCycle ? [] : outilsPermis(input.intention),
      ...(input.onEvent ? {
        cachePrompt: !dernierCycle,
        onText: (text: string) => flux.pousser(text),
      } : {}),
    });
    flux.terminer();
    inventions.push(...flux.retirees);

    entree += reponse.usage?.input ?? 0;
    sortie += reponse.usage?.output ?? 0;
    // Part servie depuis le cache de prompt. Sans ce compteur, un cache
    // devenu inopérant se paierait au prix fort en silence.
    misEnCache += reponse.usage?.cached ?? 0;

    if (reponse.text) texteFinal = reponse.text;

    if (reponse.toolCalls.length === 0) break;

    history.push({ role: 'model', content: reponse.text, toolCalls: reponse.toolCalls });

    for (const appel of reponse.toolCalls) {
      const executeur = EXECUTORS[appel.name];

      if (!executeur) {
        // Outil inventé par le modèle. On le lui dit plutôt que d'ignorer :
        // sans retour, il rappellera le même nom au tour suivant.
        history.push({
          role: 'tool',
          toolName: appel.name,
          ...(appel.id ? { toolCallId: appel.id } : {}),
          content: JSON.stringify({ erreur: `outil inconnu : ${appel.name}` }),
        });
        continue;
      }

      try {
        const resultat = await executeur(appel.args, ctx);
        if (resultat.content?.trim()) {
          reponseOutil = resultat.content.trim();
          resumeOutil = resultat.summary;
        }
        faits.ajouter(resultat.summary);
        faits.ajouter(resultat.content);
        for (const composant of resultat.components) faits.ajouter(composant.data);

        // Les identifiants viennent d'ici, et de nulle part ailleurs.
        collectIds(resultat.summary, idsAutorises);
        for (const composant of resultat.components) {
          collectIds(composant.data, idsAutorises);
        }

        // Une tentative plus précise remplace la précédente. Sans cette
        // règle, le modèle pouvait d'abord lister les boutiques proches,
        // puis trouver Garba d'Or : l'écran conservait les deux réponses et
        // affichait pharmacie, marché et Tovo Shop avant les bons produits.
        if (resultat.components.length > 0 || ['rechercher_produits', 'produits_de_boutique', 'lister_categories', 'lister_restaurants', 'boutiques_proches'].includes(appel.name)) {
          composantsDuTour.length = 0;
          composantsDuTour.push(...resultat.components);
        }

        history.push({
          role: 'tool',
          toolName: appel.name,
          ...(appel.id ? { toolCallId: appel.id } : {}),
          // Le texte des boutiquiers passe par le neutraliseur avant
          // d'entrer dans le contexte du modèle.
          content: JSON.stringify(sanitizeToolResult(resultat.summary)),
        });
      } catch (cause) {
        history.push({
          role: 'tool',
          toolName: appel.name,
          ...(appel.id ? { toolCallId: appel.id } : {}),
          content: JSON.stringify({
            erreur: cause instanceof Error ? cause.message : 'échec',
          }),
        });
      }
    }
    const verified = validateComponents(composantsDuTour, idsAutorises);
    input.onEvent?.({ type: 'results', components: verified.components });

    // Les outils de catalogue produisent déjà une base de phrase, fondée sur
    // les données réellement trouvées. Un deuxième appel de l'assistant
    // doublait presque le temps de réponse ; le rédacteur (Flash-Lite, ~0,5 s)
    // la met en mots à partir du message du client — jamais telle quelle.
    if (reponseOutil && reponse.toolCalls.length === 1) {
      texteFinal = await enMots(reponseOutil, resumeOutil, verified.components);
      input.onEvent?.({ type: 'text', text: texteFinal });
      break cyclesOrchestration;
    }
  }

  const { components, rejected } = validateComponents(composantsDuTour, idsAutorises);
  // Le texte n'annonce jamais une carte qui ne s'affiche pas.
  if (texteFinal) texteFinal = sansPromesseVide(texteFinal, components);

  // Le texte enregistré et renvoyé passe le même contrôle que celui qui
  // s'est affiché : aucune phrase n'affirme un fait absent de la base.
  if (texteFinal) {
    const verifie = verifierTexte(texteFinal, faits);
    for (const r of verifie.retirees) {
      if (!inventions.some((i) => i.phrase === r.phrase)) inventions.push(r);
    }
    texteFinal = verifie.texte;
  }

  if (!texteFinal) {
    // Un carrousel sans un mot laisse croire que la question a trouvé sa
    // réponse. Vu sur « de la crème fraîche » : trois cartes de yaourt
    // apparaissaient seules, sans que rien ne dise que le catalogue n'en
    // contient aucune.
    //
    // Le repli ne couvrait que le cas SANS composant. Or c'est justement
    // quand il y en a que le silence trompe : sans composant, l'écran reste
    // vide et personne n'est induit en erreur.
    texteFinal =
      components.length === 0
        ? "Je n'ai pas trouvé ce que vous cherchez. Reformulez, ou choisissez une catégorie."
        : "Voici ce que je trouve de plus proche. Dites-moi si ce n'est pas ça.";
  }

  const messageId = await persister(input, texteFinal, components);

  return {
    ...envelope(texteFinal, components),
    messageId,
    rejected,
    ...(inventions.length ? { inventions } : {}),
    usage: { input: entree, output: sortie, cached: misEnCache, cycles: cycles + 1 },
  };
}

/**
 * Historique récent, remis dans le format du client LLM.
 *
 * Dix messages : au-delà, le contexte enfle sans que la conversation y gagne,
 * et chaque token d'entrée est facturé à chaque tour.
 */
async function chargerHistorique(
  db: SupabaseClient,
  conversationId: string,
): Promise<{ history: LlmTurn[]; pending?: PendingMerchantChoice; affichage: boolean }> {
  const { data } = await db
    .from('messages')
    .select('role, content, components')
    .eq('conversation_id', conversationId)
    .in('role', ['user', 'assistant'])
    .order('created_at', { ascending: false })
    .limit(HISTORIQUE);

  const latest = data?.[0];
  const choices = latest?.role === 'assistant' && Array.isArray(latest.components)
    ? (latest.components as Component[]).filter((component) => component.type === 'merchant_card' && component.data.choose_branch === true)
    : [];
  const pending = choices.length ? { merchant_ids: choices.map((choice) => choice.data.id as string), query: choices[0]?.data.pending_query as string ?? '' } : undefined;
  // Ce que le client a vu en dernier : produits et boutiques du message le plus
  // récent qui en affichait. Un seul résumé, pas un par tour — le client
  // désigne ce qu'il a sous les yeux, et chaque tour résumé coûterait des
  // tokens à chaque appel.
  const lignes = data ?? [];
  let resume: string | null = null;
  let indexAffiche = -1;
  for (let i = 0; i < lignes.length; i++) {
    if (lignes[i]!.role !== 'assistant') continue;
    resume = resumeAffichage(lignes[i]!.components);
    if (resume) {
      indexAffiche = i;
      break;
    }
  }
  const history = lignes
    .map((m, i) => {
      const texte = (m.content as string) ?? '';
      return {
        role: m.role === 'assistant' ? ('model' as const) : ('user' as const),
        content: i === indexAffiche && resume ? (texte ? `${texte}\n\n${resume}` : resume) : texte,
      };
    })
    .reverse()
    .filter((t) => t.content.length > 0);
  return { history, ...(pending ? { pending } : {}), affichage: resume !== null };
}

/**
 * Enregistre le tour dans la conversation.
 *
 * Un échec d'écriture ne doit pas priver l'utilisateur de sa réponse : elle
 * est déjà calculée et payée. On renvoie `null` et on continue.
 */
async function persister(
  input: OrchestrateInput,
  contenu: string,
  components: Component[],
): Promise<string | null> {
  try {
    await input.db.from('messages').insert({
      conversation_id: input.conversationId,
      role: 'user',
      // Ce que le client relira, jamais la consigne destinée au modèle.
      content: input.messagePublic ?? input.message,
      client_message_id: input.clientMessageId,
    });

    const { data } = await input.db
      .from('messages')
      .insert({
        conversation_id: input.conversationId,
        role: 'assistant',
        content: contenu,
        components,
      })
      .select('id')
      .single();

    return (data?.id as string | undefined) ?? null;
  } catch {
    return null;
  }
}

export { LlmUnavailableError };
