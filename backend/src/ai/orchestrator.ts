import type { SupabaseClient } from '@supabase/supabase-js';
import { llmClient, LlmUnavailableError, type LlmTurn } from './llmClient.js';
import { SYSTEM_PROMPT, contexteUtilisateur } from './systemPrompt.js';
import { EXECUTORS, TOOL_DEFINITIONS, type ToolContext } from './tools.js';
import { collectIds, sanitizeToolResult, validateComponents } from './validate.js';
import { envelope, merchantCard, type ChatEnvelope, type Component } from '../components/builders.js';
import { ailleursEnPlus, alternativesHorsTovo, commercesDuTypeDemande, cataloguePage, horsTovo, resolveCatalogueIntent, merchantIntentAnswer, searchAnswer, type CataloguePage, type CatalogueAnswer, type PendingMerchantChoice } from '../services/catalogue.js';
import { ajouterALaNote } from '../services/noteCommande.js';
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
import type { Rayon, TypeCommerceCherche } from './decideur.js';
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
  /** Article 7 : le client veut d'autres résultats que ceux déjà montrés. */
  suite?: boolean | undefined;
  /** Le type de commerce cherché (« un supermarché pas loin »). */
  commerce?: TypeCommerceCherche | undefined;
  /** Article 9 : une précision à garder pour la commande (« sans oignons »). */
  precision?: string | undefined;
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
  // Les détecteurs lisent les mots du CLIENT, jamais la note d'aiguillage
  // ajoutée pour l'assistant : celle de « designe » cite « le deuxième,
  // celui-là… », et « sans oignons » passait pour une désignation (05/10).
  const parole = input.messagePublic ?? input.message;
  const reference = !input.audio && referenceAuxResultats(parole);
  // « Comme d'habitude » : aucun produit dans la phrase, seul le modèle sait
  // relire l'historique des commandes. Toujours au modèle, affichage ou pas.
  const commandePassee = !input.audio && demandeDeCommandePassee(parole);
  // « De la viande chez Tchos » : la boutique nommée décide. Le produit et le
  // rayon du cerveau (« viande Tchos », repas) ramenaient Maison Grill.
  const boutiqueNommee = !input.audio && Boolean(nomBoutiqueApresMarqueur(parole));
  const requeteInitiale = input.audio ? ''
    : requeteProduitUtilisateur((boutiqueNommee ? undefined : input.requete) ?? parole);
  // Recherche ou boutique : le catalogue a son mot à dire. Toute autre route
  // connue va droit au modèle.
  const catalogueAutorise = !input.intention || input.intention === 'recherche' || input.intention === 'boutique';
  // Le rayon compris par le cerveau : la recherche y reste (« huile » →
  // supermarché, jamais les huiles d'argan de la beauté).
  const rayonId = input.rayon && !input.audio && !boutiqueNommee ? await idDuRayon(input.db, input.rayon) : undefined;
  // Le cerveau a compris une recherche et dit quoi chercher : le filtre à
  // mots ne la refuse plus. « un colis de riz » contient « colis », et
  // partait à l'assistant alors que le cerveau disait « riz » (02/10).
  const rechercheDuCerveau = input.intention === 'recherche' && Boolean(input.requete);
  // Une BOUTIQUE nommée (« Otakoss ») : on cherche la boutique, jamais des
  // produits au nom proche — « takoss » sonne comme « tacos », et des tacos
  // d'autres enseignes s'affichaient à la place du choix d'agence (05/10).
  const rapide = (requete: string) => requete.length > 0 && input.intention !== 'boutique'
    && (rechercheDuCerveau || rechercheProduitRapide(parole, requete));
  const rechercheInitiale = input.pageInitiale
    ? Promise.resolve(input.pageInitiale)
    : !input.audio && !reference && !commandePassee && catalogueAutorise
    && rapide(requeteInitiale)
    // Premier passage lexical uniquement : il doit rester plus rapide qu'un
    // appel modèle. Les fautes et rapprochements sémantiques restent pris en
    // charge par le chemin complet juste après.
    ? cataloguePage(input.db, { q: requeteInitiale, limit: 8, category_id: rayonId }, false)
    : Promise.resolve(null);
  const [previous, pageTrouvee] = await Promise.all([historique, rechercheInitiale]);
  // Article 2 : un choix attend une réponse (« Centre Aéré ou Nouveau Marché
  // ? ») — il passe AVANT toute recherche. « centre aéré » trouvait sinon des
  // produits ou des commerces au lieu de désigner l'agence proposée (05/10).
  const pageInitiale = previous.pending && !input.pageInitiale ? null : pageTrouvee;

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
    // Article 8 : ce qui existe ailleurs fait partie de la réponse, sous Tovo.
    reponse = await avecAilleurs(reponse);
    const jugement = await redigerEtJuger({ message: input.messagePublic ?? input.message, prevue: reponse.content,
      faits: reponse.summary, composants: reponse.components, avant: dernierDeTovo });
    const j = avecLesProduitsDuNom(reponse, jugement);
    // Une partie seulement répond (des merguez mêlées de tacos) : on ne garde
    // qu'elle, et la phrase est réécrite sur ce qui reste.
    if (j.pertinent === true && j.garder) {
      const triee = seulementPertinents(reponse, j.garder);
      if (triee !== reponse) {
        // Sur ce qui reste, ce qui existe ailleurs (moins de résultats, plus d'aide).
        const filtree = await avecAilleurs(triee);
        return { reponse: filtree, phrase: await enMots(filtree.content, filtree.summary, filtree.components) };
      }
    }
    if (j.pertinent === false) {
      const ailleurs = await horsTovo(input.db, parole, input.requete ?? requeteInitiale, input.position);
      // Article 6 : jamais de produits sans rapport, même faute de mieux.
      const repli = ailleurs ?? {
        content: 'Tovo n’en propose pas pour le moment.',
        summary: { aucun_resultat_pertinent: true, demande: input.requete ?? requeteInitiale },
        components: [],
      };
      return { reponse: repli, phrase: await enMots(repli.content, repli.summary, repli.components) };
    }
    return { reponse, phrase: j.texte };
  };

  /**
   * Article 6, dans les deux sens : un produit dont le NOM contient ce que le
   * client cherche (« Riz basmati » pour « riz ») y répond — le juge ne peut
   * pas l'écarter. Il rejetait parfois six riz, et Tovo disait « pas de riz »
   * (05/10). Le juge garde la main sur tout le reste.
   */
  function avecLesProduitsDuNom<J extends { pertinent: boolean | null; garder: ReadonlySet<string> | null }>(
    reponse: CatalogueAnswer, j: J,
  ): J {
    const mots = normaliserIntention(input.requete ?? requeteInitiale).split(' ').filter((m) => m.length >= 3);
    // Sans jugement (panne, délai), rien n'est trié : la règle corrige le juge,
    // elle ne le remplace pas.
    if (mots.length === 0 || j.pertinent === null) return j;
    // Le nom doit COMMENCER par ce qui est cherché : « Riz basmati » est du riz,
    // « Savon au lait » est un savon (il gardait sinon les savons pour « lait »).
    const singulier = (m: string) => m.replace(/s$/, '');
    const premierMot = (nom: string) => normaliserIntention(nom).split(' ')
      .find((m) => m.length > 1 && !['le', 'la', 'les', 'du', 'de', 'des', 'un', 'une'].includes(m)) ?? '';
    const parLeNom = reponse.components
      .filter((c) => c.type === 'product_carousel' || c.type === 'product_list')
      .flatMap((c) => (Array.isArray(c.data.items) ? c.data.items as Array<{ id?: string; name?: string }> : []))
      .filter((i) => singulier(premierMot(String(i.name ?? ''))) === singulier(mots[0]!))
      .map((i) => String(i.id));
    if (parLeNom.length === 0) return j;
    return { ...j, pertinent: true, garder: new Set([...(j.garder ?? []), ...parLeNom]) };
  }

  /**
   * Article 8 : sous les produits Tovo, les commerces hors Tovo utiles
   * (ailleursEnPlus) — le client ne sait pas qu'il pourrait les demander.
   */
  async function avecAilleurs(reponse: CatalogueAnswer): Promise<CatalogueAnswer> {
    if (reponse.components.some((c) => c.type === 'commerces_hors_tovo')) return reponse;
    const total = typeof reponse.summary.total === 'number' ? reponse.summary.total as number
      : reponse.components.reduce((n, c) => n + (Array.isArray(c.data.items) ? (c.data.items as unknown[]).length : 0), 0);
    const ailleurs = await ailleursEnPlus(input.db, input.requete ?? requeteInitiale, input.position, total);
    if (!ailleurs) return reponse;
    return {
      content: `${reponse.content} ${ailleurs.content}`,
      summary: { ...reponse.summary, ...ailleurs.summary },
      components: [...reponse.components, ...ailleurs.components],
    };
  }

  // Une réponse directe : les cartes, puis la phrase du rédacteur.
  const repondre = async (reponse: CatalogueAnswer) => {
    input.onEvent?.({ type: 'results', components: reponse.components });
    const phrase = await enMots(reponse.content, reponse.summary, reponse.components);
    input.onEvent?.({ type: 'text', text: phrase });
    const messageId = await persister(input, phrase, reponse.components);
    return { ...envelope(phrase, reponse.components), messageId, rejected: [],
      usage: { input: 0, output: 0, cached: 0, cycles: 0 } };
  };

  // ARTICLE 2 — un choix attend une réponse : il se résout EN PREMIER, avant
  // la suite, la précision ou toute recherche, quelle que soit l'intention
  // lue. « centre aéré » après « Centre Aéré ou Nouveau Marché ? » était lu
  // une fois sur quatre comme « suite » et partait vers des commerces hors
  // Tovo (05/10). Si la phrase ne désigne aucune des adresses proposées, le
  // chemin habituel reprend.
  if (previous.pending && !input.audio) {
    const choix = await resolveCatalogueIntent(input.db, parole, previous.pending);
    if (choix.merchants.length === 1 && previous.pending.merchant_ids.includes(choix.merchants[0]!.id)
        && choix.query === previous.pending.query) {
      const reponse = await merchantIntentAnswer(input.db, choix);
      if (reponse) return repondre(reponse);
    }
  }

  // UN TYPE DE COMMERCE (« un supermarché pas loin », « tous les supermarchés
  // de Niamey ») : Tovo d'abord, puis l'annuaire (articles 7 et 8). Une suite
  // (« plus loin », « d'autres ») reprend le type affiché, sans ce qui a déjà
  // été montré.
  {
    const memoire = previous.dernierAffichage.find((c) => c.data.commerce_type)?.data as
      { commerce_type?: TypeCommerceCherche; deja_vus_boutiques?: string[]; deja_vus_commerces?: string[] } | undefined;
    const typeAffiche = memoire?.commerce_type;
    const type = input.commerce ?? (input.suite ? typeAffiche : undefined);
    if (type && !input.audio && !boutiqueNommee) {
      // Ce qui a déjà été montré pour ce type, depuis le début de la recherche.
      const continuer = Boolean(input.suite || (input.commerce && input.commerce === typeAffiche));
      const dejaVus = {
        boutiques: new Set(continuer ? memoire?.deja_vus_boutiques ?? [] : []),
        commerces: new Set(continuer ? memoire?.deja_vus_commerces ?? [] : []),
      };
      const liste = await commercesDuTypeDemande(input.db, type, input.position, dejaVus);
      if (liste) return repondre(liste);
      if (dejaVus.boutiques.size + dejaVus.commerces.size > 0) {
        return repondre({ content: 'Je vous ai montré tous ceux que je connais dans les environs.', summary: { type_de_commerce: type, tout_montre: true }, components: [] });
      }
    }
  }

  // ARTICLE 9 — ce que le client précise est GARDÉ : la note de commande,
  // que la boutique lira et que le client modifie au panier. Si rien d'autre
  // n'est demandé (pas de recherche), la réponse s'arrête là. Article 4 : on
  // ne dit « c'est noté » que si l'écriture a réussi.
  // Désigner un article affiché (« ajoute la première ») n'est pas une
  // précision : le cerveau le classait parfois ainsi, et rien n'était ajouté
  // (05/10). La désignation suit son chemin habituel.
  if (input.precision && !input.audio && !reference) {
    const note = await ajouterALaNote(input.db, input.userId, input.precision);
    if (!catalogueAutorise || input.intention === 'designe') {
      const panier = note
        ? await EXECUTORS.voir_panier!({}, { db: input.db, userId: input.userId, ...(input.position ? { position: input.position } : {}) })
        : null;
      return repondre({
        content: note
          ? `C’est gardé pour votre commande : « ${note} ». La boutique le verra avec la commande, et vous pouvez le modifier au panier.`
          : 'Je n’arrive pas à garder cette précision pour le moment. Vous pourrez l’écrire dans la note au moment de commander.',
        summary: { precision: input.precision, enregistree: Boolean(note), note_de_commande: note },
        components: panier?.components ?? [],
      });
    }
  }

  // ARTICLE 7 — « d'autres », « encore », « plus loin » : ce que le client n'a
  // PAS encore vu. La suite du catalogue, puis les commerces hors Tovo (où
  // qu'ils soient : « Nouhou Merguez » pour d'autres vendeurs de merguez).
  if (input.suite && !input.audio) {
    const suite = await laSuite(input, previous.dernierAffichage, requeteInitiale);
    if (suite) {
      // Article 6 aussi pour la suite : seulement ce qui répond (« plus loin »
      // montrait une Vaseline pour une pommade Nivea).
      const avecProduits = suite.components.some((c) => c.type === 'product_carousel' || c.type === 'product_list');
      if (!avecProduits) return repondre(suite);
      const j = await redigerEtJuger({ message: input.messagePublic ?? input.message, prevue: suite.content,
        faits: suite.summary, composants: suite.components, avant: dernierDeTovo });
      const gardee = j.garder ? seulementPertinents(suite, j.garder) : suite;
      return repondre(gardee.components.length ? gardee : {
        content: 'Je n’ai rien d’autre qui corresponde vraiment à votre demande.',
        summary: { suite_de: input.requete ?? requeteInitiale, rien_d_autre: true },
        components: [],
      });
    }
  }

  const photoRecente = previous.history.slice(-4).some((turn) =>
    turn.role === 'user' && /photo envoyee/i.test(normaliserIntention(turn.content)));
  const correctionPhoto = !versModele && photoRecente
    && /^(?:mais )?(?:c est|ce sont) (?:un |une |des )?/i.test(normaliserIntention(parole));
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
    // Article 1 : un seul interprète. Le cerveau a compris une boutique et la
    // nomme (« centre aéré », réponse au choix d'agence → « O'TAKOSS Centre
    // Aéré ») : c'est elle qu'on cherche, pas les mots bruts — sauf si la
    // phrase nomme la boutique elle-même (« chez Tchos » garde son marqueur).
    : await resolveCatalogueIntent(input.db,
      input.intention === 'boutique' && input.requete && !boutiqueNommee ? input.requete : parole,
      previous.pending);
  let direct = intent ? await merchantIntentAnswer(input.db, intent) : null;
  // Ce que le cerveau a compris (« merguez »), sauf quand une boutique est
  // nommée : la requête est alors ce qui reste une fois son nom retiré.
  const requeteClient = input.requete && intent && intent.merchants.length === 0 && !intent.missing
    ? requeteProduitUtilisateur(input.requete)
    : requeteProduitUtilisateur(intent?.query ?? parole);
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
      direct = await horsTovo(input.db, parole, requeteClient || intent.query, input.position,
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
      && demandeBoutiqueOuverte(parole)) {
    const ouvertes = input.position
      ? await EXECUTORS.boutiques_proches!({}, {
        db: input.db,
        userId: input.userId,
        currentMessage: parole,
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
    currentMessage: input.audio ? undefined : parole,
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
  faits.ajouterParole(parole);
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
    let approchant = false;
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
        // Des ressemblances seulement (« console de jeu » pour « livres pour
        // enfants ») : jugées plus bas, avant d'être montrées (article 6).
        if (appel.name === 'rechercher_produits' && (resultat.summary as { suggestions?: unknown } | undefined)?.suggestions === true) {
          approchant = true;
        }

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
    // ARTICLE 6 — un résultat approchant sans rapport ne se montre pas : on
    // dit où le trouver ailleurs, ou qu'on n'en a pas. Le même jugement que
    // sur les voies rapides (produitsOuAilleurs), sur le chemin de l'assistant.
    if (approchant && composantsDuTour.some((c) => c.type === 'product_carousel' || c.type === 'product_list')) {
      const j = await redigerEtJuger({ message: input.messagePublic ?? input.message, prevue: reponseOutil ?? '',
        faits: resumeOutil, composants: composantsDuTour, avant: dernierDeTovo });
      if (j.pertinent === true && j.garder) {
        const filtres = seulementPertinents({ content: '', summary: {}, components: [...composantsDuTour] }, j.garder).components;
        composantsDuTour.length = 0;
        composantsDuTour.push(...filtres);
      }
      if (j.pertinent === false) {
        const ailleurs = await horsTovo(input.db, parole, input.requete ?? requeteInitiale, input.position);
        composantsDuTour.length = 0;
        composantsDuTour.push(...(ailleurs?.components ?? []));
        reponseOutil = ailleurs?.content ?? 'Tovo n’en propose pas pour le moment.';
        resumeOutil = ailleurs?.summary ?? { aucun_resultat_pertinent: true };
        faits.ajouter(resumeOutil);
        for (const composant of composantsDuTour) collectIds(composant.data, idsAutorises);
      }
    }
    if (approchant || reponseOutil) {
      const restants = composantsDuTour.filter((c) => c.type === 'product_carousel' || c.type === 'product_list');
      if (restants.length > 0) {
        const complet = await avecAilleurs({ content: reponseOutil ?? '', summary: (resumeOutil ?? {}) as Record<string, unknown>, components: [...composantsDuTour] });
        if (complet.components.length > composantsDuTour.length) {
          composantsDuTour.length = 0;
          composantsDuTour.push(...complet.components);
          reponseOutil = complet.content;
          resumeOutil = complet.summary;
          faits.ajouter(complet.summary);
        }
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
 * ARTICLE 6 — ne garder, dans les listes de produits, que ceux que le juge a
 * reconnus comme répondant à la demande. Une liste vidée disparaît. La même
 * réponse (même objet) si rien n'est retiré.
 */
function seulementPertinents(reponse: CatalogueAnswer, garder: ReadonlySet<string>): CatalogueAnswer {
  let retire = false;
  const components = reponse.components.flatMap((c) => {
    if (c.type !== 'product_carousel' && c.type !== 'product_list') return [c];
    const items = Array.isArray(c.data.items) ? c.data.items as Array<{ id?: string }> : [];
    const gardes = items.filter((i) => garder.has(String(i.id)));
    if (gardes.length === items.length) return [c];
    retire = true;
    // Sans « browse » : « Parcourir les N autres » ramènerait les produits retirés.
    const { browse: _browse, ...data } = c.data as Record<string, unknown>;
    return gardes.length ? [{ ...c, data: { ...data, items: gardes } }] : [];
  });
  if (!retire) return reponse;
  // Le total de la recherche ne vaut plus, ni la phrase qui le citait (« 5
  // références » pour un seul produit montré, 05/10) : seulement ce qui reste.
  // Les commerces hors Tovo sont retirés aussi : ils seront recalculés sur ce
  // qui reste (avecAilleurs) — peu de résultats en appellent davantage.
  const { total: _total, produits: _produits, aussi_hors_tovo: _ailleurs, ...summary } = reponse.summary as Record<string, unknown>;
  const gardees = components.filter((c) => c.type !== 'commerces_hors_tovo');
  const montres = gardees.flatMap((c) => (Array.isArray(c.data.items) ? c.data.items as Array<{ name?: string }> : []));
  return {
    content: montres.length === 1 ? 'Voici ce qui correspond à votre demande.' : `Voici les ${montres.length} produits qui correspondent à votre demande.`,
    components: gardees,
    summary: { ...summary, produits_qui_repondent: montres.map((i) => i.name), nombre: montres.length },
  };
}

/**
 * ARTICLE 7 — ce que le client n'a pas encore vu, pour la même demande :
 *  - la suite du catalogue, après les produits déjà montrés ;
 *  - les commerces hors Tovo qui en ont probablement, sauf ceux déjà montrés
 *    (tous types, jusqu'à 20 km).
 * null s'il n'y a pas de demande à prolonger (le chemin habituel reprend).
 */
async function laSuite(input: OrchestrateInput, vu: Component[], requeteInitiale: string): Promise<CatalogueAnswer | null> {
  const liste = vu.find((c) => c.type === 'product_carousel' || c.type === 'product_list');
  const parcourir = (liste?.data.browse ?? {}) as { query?: string; total?: number; merchant_ids?: string[]; category_id?: string };
  const commercesVus = vu.find((c) => c.type === 'commerces_hors_tovo');
  const sujetAffiche = String(parcourir.query || commercesVus?.data.produit || '').trim();
  // Article 2 : ce qui est à l'écran donne le sens. Le sujet de ce qui était
  // affiché passe avant la relecture du cerveau, qui prenait « Haute Qualité
  // et couture » (le commerce montré) pour le produit (« plus loin ? » →
  // « pas d'autres boutiques de couture », 02/10).
  const requete = (sujetAffiche || input.requete || (liste ? requeteInitiale : '') || '').trim();
  if (!requete) return null;
  const montres = Array.isArray(liste?.data.items) ? (liste!.data.items as unknown[]).length : 0;

  const filtre = { q: requete, limit: 8, offset: montres,
    ...(parcourir.merchant_ids?.length ? { merchant_ids: parcourir.merchant_ids } : {}),
    ...(parcourir.category_id ? { category_id: parcourir.category_id } : {}) };
  // Aucune liste Tovo montrée encore : le catalogue entier est « pas encore vu ».
  const page = !liste || (parcourir.total ?? 0) > montres ? await cataloguePage(input.db, filtre, false) : null;
  const autresProduits = page && page.items.length > 0 ? searchAnswer(page, filtre) : null;

  const dejaVus = new Set(vu.filter((c) => c.type === 'commerces_hors_tovo')
    .flatMap((c) => (Array.isArray(c.data.items) ? c.data.items as Array<{ nom?: string }> : []).map((i) => String(i.nom ?? ''))));
  // « Plus loin » : au-delà du plus éloigné déjà montré (sinon on proposait
  // un commerce à 530 m après un autre à 1,1 km, 05/10).
  const distancesVues = vu.filter((c) => c.type === 'commerces_hors_tovo')
    .flatMap((c) => (Array.isArray(c.data.items) ? c.data.items as Array<{ distance_m?: number | null }> : []))
    .map((i) => i.distance_m).filter((d): d is number => typeof d === 'number');
  const auDelaDe = distancesVues.length ? Math.max(...distancesVues) : 0;
  const ailleurs = await alternativesHorsTovo(input.db, requete, input.position, requete, { dejaVus, auDelaDe });

  if (!autresProduits && !ailleurs) {
    return {
      content: `Je n’ai rien d’autre pour « ${requete} » que ce que je vous ai déjà montré.`,
      summary: { suite_de: requete, rien_d_autre: true },
      components: [],
    };
  }
  return {
    content: [
      autresProduits ? 'Voici d’autres choix sur Tovo.' : '',
      ailleurs ? 'Hors de Tovo, ces commerces en ont probablement ; un livreur peut y aller, il vous appelle pour convenir de l’achat.' : '',
    ].filter(Boolean).join(' '),
    summary: {
      suite_de: requete,
      ...(autresProduits ? { autres_produits_tovo: autresProduits.summary } : {}),
      ...(ailleurs ? { commerces_hors_tovo: ailleurs.summary } : {}),
      consigne: 'Le client a demandé d’autres choix : ce sont des choix qu’il n’avait pas encore vus. Dis-le simplement, sans répéter les précédents.',
    },
    components: [...(autresProduits?.components ?? []), ...(ailleurs?.components ?? [])],
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
): Promise<{ history: LlmTurn[]; pending?: PendingMerchantChoice; affichage: boolean; dernierAffichage: Component[] }> {
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
  // Les cartes du dernier message qui en montrait : ce que le client a vu
  // (article 7 — « d'autres » part de là).
  const dernierAffichage = (lignes.find((m) => m.role === 'assistant' && Array.isArray(m.components) && (m.components as unknown[]).length > 0)
    ?.components ?? []) as Component[];
  return { history, ...(pending ? { pending } : {}), affichage: resume !== null, dernierAffichage };
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
