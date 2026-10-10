import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';
import { ChatUnavailableError, orchestrate } from '../ai/orchestrator.js';
import { LlmUnavailableError, llmEnabled } from '../ai/llmClient.js';
import { ANNULER_CONFIRME, EXECUTORS, GARDER_COMMANDE, annulerConfirme } from '../ai/tools.js';
import {
  demandeDeCommandePassee,
  demandeGeneraleDeRepas,
  demandeDeRecuperation,
  demandeUnColis,
  demandeUnLivreur,
  referenceAuxResultats,
  requeteProduitUtilisateur,
  normaliserIntention,
} from '../ai/intents.js';
import { signaler } from '../lib/observability.js';
import { env } from '../config/env.js';
import { comparerRoutesMai, transcrire } from '../services/transcription.js';
import { chatStream } from '../lib/chatStream.js';
import { consommer, messageLimite } from '../services/rateLimit.js';
import { courseDejaEnRoute } from '../services/livreur.js';
import { ombreJev, type Intention } from '../ai/jev.js';
import { ouvrirSessionVoix, vocabulaire } from '../services/voixDirecte.js';
import { decider, indication, intentionChoisie, routeDuCerveau, type Route } from '../ai/aiguillage.js';
import { cerveauActif, comprendre, type Details, type Rayon, type TypeCommerceCherche } from '../ai/decideur.js';
import { commandeEnCours, etatDuParcours } from '../ai/etat.js';
import { exemplesPour } from '../ai/banc/exemples.js';
import { aiguiller, cascadeActive } from '../ai/cascade.js';
import { rechercheProduitRapide } from '../ai/orchestrator.js';
import { cataloguePage, HORS_TOVO_NON, HORS_TOVO_OUI, reponseHorsTovo, type CataloguePage } from '../services/catalogue.js';
import { demandeDeGarde, reponseGarde } from '../services/pharmaciesGarde.js';
import { corrigerLieuxDuTexte, quartierApproche, reperer } from '../services/lieux.js';
import { avecPreuves } from '../ai/verificateur.js';
import {
  argumentsDeLaCourse, completerCourse, decrireMemoire, DUREE_DE_VIE_MS, lireConversation, type Ligne, type Memoire,
} from '../ai/conversation.js';
import { rediger } from '../ai/redacteur.js';
import { serviceClient } from '../services/supabase.js';
import { orderTracking, type Component } from '../components/builders.js';

/**
 * POST /chat — le fil conversationnel.
 *
 * L'app envoie soit du texte, soit une interaction issue d'un composant.
 * Les deux deviennent un message pour le modèle ; l'enveloppe qui revient est
 * la même que celle des routes REST, si bien que Flutter ne fait aucune
 * différence entre un panier renvoyé par un tap et un panier renvoyé par
 * l'assistant.
 *
 * `client_message_id` rend l'appel idempotent : sur un réseau qui coupe, un
 * rejeu ne doit pas relancer le modèle ni facturer deux fois.
 */

const interactionSchema = z.object({
  action: z.string().min(1).max(60),
  payload: z.record(z.unknown()).default({}),
});

/**
 * Message vocal.
 *
 * Plafonné à 700 000 caractères de base64, soit environ 512 Ko — deux
 * minutes d'AAC à 32 kbit/s, largement au-delà des 60 s que l'app autorise.
 * Ce plafond protège des requêtes qui ne viennent pas d'elle : un
 * enregistrement de dix minutes se facturerait au prix fort et mettrait
 * longtemps à revenir.
 *
 * L'enregistrement DOIT être compressé. Mesuré : six secondes de WAV pèsent
 * 286 Ko, là où une minute d'AAC en fait 240. Un client sur réseau nigérien
 * n'enverra jamais du WAV dans un délai acceptable.
 *
 * Formats acceptés : ceux que Gemini comprend nativement, et ceux qu'un
 * téléphone produit sans transcodage.
 */
const audioSchema = z.object({
  mime: z.enum(['audio/ogg', 'audio/mp4', 'audio/mpeg', 'audio/aac', 'audio/wav', 'audio/webm']),
  data: z.string().min(1).max(700_000),
});

const chatSchema = z
  .object({
    conversation_id: z.string().uuid().optional(),
    client_message_id: z.string().uuid(),
    text: z.string().min(1).max(2000).optional(),
    interaction: interactionSchema.optional(),
    audio: audioSchema.optional(),
    context: z
      .object({
        lat: z.number().min(-90).max(90),
        lng: z.number().min(-180).max(180),
      })
      .optional(),
  })
  .refine(
    (v) => [v.text, v.interaction, v.audio].filter(Boolean).length === 1,
    { message: 'fournir « text », « interaction » OU « audio » — un seul' },
  );

/**
 * Traduit une interaction en intention lisible par le modèle.
 *
 * Le modèle n'a pas à connaître le protocole de l'interface : il lit une
 * phrase, comme si l'utilisateur l'avait tapée.
 */
function interactionEnMessage(action: string, payload: Record<string, unknown>): string {
  switch (action) {
    case 'select_category':
      return `Je veux voir la catégorie ${payload.category_id}.`;
    case 'select_product':
      return `Montre-moi le produit ${payload.product_id} et ses options.`;
    case 'select_merchant':
      return `Montre-moi ce que propose la boutique ${payload.merchant_id}.`;
    case 'add_to_cart':
      return `Ajoute au panier le produit ${payload.product_id}, quantité ${payload.quantity ?? 1}, options ${JSON.stringify(payload.selections ?? [])}.`;
    case 'remove_from_cart':
      return `Retire du panier l'article ${payload.item_id}.`;
    case 'open_cart':
      return 'Montre-moi mon panier.';
    case 'search_by_image':
      return `J'ai envoyé une photo, cherche ce produit. image_path : ${payload.image_path}${legendePhoto(payload) ? ` ; indication : ${legendePhoto(payload)}` : ''}`;
    case 'compare_price':
      return `Compare les prix pour : ${payload.query}.`;
    case 'quick_reply': {
      const libelle = String(payload.label ?? '');
      const valeur = String(payload.value ?? '');
      // La VALEUR en plus du libellé quand elle dit autre chose.
      //
      // « Reprendre : Tacos XL » a pour valeur « recommander:<uuid> », et
      // seul le libellé partait au modèle. Il voyait donc un bouton sans
      // savoir sur quelle commande il portait, et ne pouvait rien en faire.
      //
      // Le client, lui, continue de ne relire que le libellé : c'est
      // `libelleLisible` qui décide de ce qui est conservé.
      if (valeur && valeur !== libelle) {
        return libelle ? `${libelle} [${valeur}]` : valeur;
      }
      return libelle || valeur;
    }
    default:
      return `Action : ${action} ${JSON.stringify(payload)}`;
  }
}

function legendePhoto(payload: Record<string, unknown>): string {
  return typeof payload.caption === 'string' ? payload.caption.trim().slice(0, 2000) : '';
}

/**
 * Ce que le client relira dans son historique.
 *
 * Distinct de la consigne envoyée au modèle : celle-ci contient des
 * identifiants, des chemins de fichiers et des instructions à la deuxième
 * personne. Enregistrée telle quelle, elle réapparaissait dans le fil à la
 * réouverture de la conversation — « J'ai envoyé une photo, cherche ce
 * produit. image_path : a7b7d19d-84e7-460e… » dans une bulle censée être la
 * parole du client.
 *
 * `null` quand la consigne est déjà lisible : un « Montre-moi mon panier »
 * n'a pas besoin d'être reformulé.
 */
function libelleLisible(action: string, payload: Record<string, unknown>): string | null {
  switch (action) {
    case 'search_by_image':
      return legendePhoto(payload) ? `📷 ${legendePhoto(payload)}` : '📷 Photo envoyée';
    case 'select_category':
    case 'select_product':
    case 'select_merchant':
    case 'add_to_cart':
    case 'remove_from_cart':
      // Ces actions portent un UUID que personne ne veut relire. Le libellé
      // exact du produit n'est pas connu ici, mais l'intention suffit à
      // rendre le fil compréhensible.
      return null;
    case 'quick_reply':
      return String(payload.label ?? payload.value ?? '');
    default:
      return null;
  }
}

export async function chatRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Voix en direct : jeton temporaire pour parler à Gemini Live depuis le
   * téléphone (voir services/voixDirecte.ts). Compté comme une transcription
   * dans la limite de débit. 503 : l'app bascule sur POST /transcriptions.
   */
  app.post('/transcriptions/session', { preHandler: app.requireAuth }, async (request, reply) => {
    const limite = await consommer('transcription', request.user!.id);
    if (!limite.ok) {
      return reply
        .code(429)
        .header('retry-after', String(limite.reessayerDans))
        .send({ error: messageLimite(limite.reessayerDans) });
    }
    try {
      const session = await ouvrirSessionVoix(request.supabase!);
      if (!session) return reply.code(503).send({ error: 'La voix en direct est indisponible.' });
      return reply.send(session);
    } catch (cause) {
      request.log.error({ cause: cause instanceof Error ? cause.message : cause }, 'jeton de voix impossible');
      return reply.code(503).send({ error: 'La voix en direct est indisponible.' });
    }
  });

  // Plus large que l'audio du chat : c'est aussi le SECOURS de la voix en
  // direct, qui renvoie alors le son brut (WAV 16 kHz, ~32 Ko/s) — une
  // minute pèse ~2 Mo, ~2,6 Mo en base64.
  app.post('/transcriptions', { preHandler: app.requireAuth, bodyLimit: 4 * 1024 * 1024 }, async (request, reply) => {
    const body = z.object({
      audio: audioSchema.extend({ data: z.string().min(1).max(2_800_000) }),
    }).safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: 'enregistrement invalide' });
    const limite = await consommer('transcription', request.user!.id);
    if (!limite.ok) {
      return reply
        .code(429)
        .header('retry-after', String(limite.reessayerDans))
        .send({ error: messageLimite(limite.reessayerDans) });
    }
    const started = performance.now();
    try {
      // Plats locaux et noms des boutiques : MAI les écrit juste avec la liste.
      const mots = await vocabulaire(request.supabase!).catch(() => []);
      const { texte: brut, fournisseur } = await transcrire(body.data.audio, mots);
      // Un nom de lieu mal entendu (« à Gobien » pour Bobiel, 10/10) est
      // corrigé DANS le texte : le client lit le bon nom dans son message,
      // le même que sur la carte (services/lieux.ts).
      const transcript = corrigerLieuxDuTexte(brut, mots);
      // Qui a répondu, et en combien de temps : c'est ce qui dira, en
      // production, si le secours sert souvent et s'il faut changer de route.
      request.log.info(
        { duration_ms: Math.round(performance.now() - started), fournisseur, octets: body.data.audio.data.length },
        'transcription terminee',
      );
      if (!transcript) return reply.code(422).send({ error: 'Je n’ai pas distingué de paroles. Réessayez dans un endroit plus calme.' });
      // Ombre : APRÈS la réponse, la même note par les deux routes vers MAI,
      // pour les comparer depuis Railway. Le client n'attend rien.
      if (Math.random() < env.TRANSCRIPTION_OMBRE) {
        void comparerRoutesMai(body.data.audio, mots)
          .then((comparaison) => {
            if (comparaison) request.log.info(comparaison, 'transcription ombre');
          })
          .catch(() => {});
      }
      return reply.send({ transcript });
    } catch {
      return reply.code(503).send({ error: 'La transcription est indisponible. Réessayez ou écrivez votre demande.' });
    }
  });
  /**
   * La dernière conversation, pour la reprendre à l'ouverture.
   *
   * Les échanges étaient enregistrés depuis toujours et jamais relus : chaque
   * lancement ouvrait une conversation neuve, et tout ce que le client avait
   * dit la veille devenait invisible. Il repartait de zéro sans comprendre
   * pourquoi l'assistant ne se souvenait de rien.
   */
  /** Les conversations du client, pour la barre latérale. */
  app.get('/conversations', { preHandler: app.requireAuth }, async (request, reply) => {
    const { data, error } = await request.supabase!.rpc('my_conversations', {
      p_limite: 30,
    });

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }
    return reply.send({ conversations: data ?? [] });
  });

  /**
   * Les messages d'une conversation précise.
   *
   * La RLS suffit à en limiter l'accès : `conversations` et `messages` sont
   * filtrées sur `auth.uid()`. Demander celle d'un autre renvoie une liste
   * vide, jamais une erreur qui confirmerait son existence.
   */
  app.get('/conversations/:id', { preHandler: app.requireAuth }, async (request, reply) => {
    const params = z.object({ id: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { data, error } = await request.supabase!
      .from('messages')
      .select('role, content, components, created_at')
      .eq('conversation_id', params.data.id)
      .in('role', ['user', 'assistant'])
      .order('created_at', { ascending: true })
      .limit(50);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send({
      conversation_id: params.data.id,
      messages: (data ?? []).map((m) => ({
        role: m.role as string,
        content: (m.content as string | null) ?? '',
        components: (m.components as unknown[] | null) ?? [],
      })),
    });
  });

  app.get('/conversations/last', { preHandler: app.requireAuth }, async (request, reply) => {
    const db = request.supabase!;

    const { data: conversation } = await db
      .from('conversations')
      .select('id')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!conversation) return reply.send({ conversation_id: null, messages: [] });

    const conversationId = (conversation as { id: string }).id;

    // Les dix derniers, remis dans l'ordre de lecture. Au-delà, le fil
    // s'allonge sans rien apporter et l'ouverture ralentit.
    const { data, error } = await db
      .from('messages')
      .select('role, content, components, created_at')
      .eq('conversation_id', conversationId)
      .in('role', ['user', 'assistant'])
      .order('created_at', { ascending: false })
      .limit(10);

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    const messages = (data ?? [])
      .reverse()
      .map((m) => ({
        role: m.role as string,
        content: (m.content as string | null) ?? '',
        components: (m.components as unknown[] | null) ?? [],
      }))
      .filter((m) => m.content.length > 0 || m.components.length > 0);

    return reply.send({ conversation_id: conversationId, messages });
  });

  app.post('/chat', { preHandler: app.requireAuth }, async (request, reply) => {
    const body = chatSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const db = request.supabase!;
    const userId = request.user!.id;
    const streaming = request.headers.accept?.includes('application/x-ndjson') === true;

    // Avant tout le reste, y compris la création de conversation : un client
    // limité ne doit ni appeler le modèle ni écrire en base. Un rejeu réseau
    // compte aussi — c'est rare, et la limite est large.
    const limite = await consommer('chat', userId);
    if (!limite.ok) {
      request.log.warn({ userId, reessayer_dans_s: limite.reessayerDans }, 'limite de débit atteinte');
      return reply
        .code(429)
        .header('retry-after', String(limite.reessayerDans))
        .send({ error: messageLimite(limite.reessayerDans) });
    }

    // Mode ombre : Jev classe le message en arrière-plan, sans rien retarder
    // ni influencer (voir ai/jev.ts). Inactif sans JEV_OMBRE=1.
    if (body.data.text) ombreJev(body.data.text, request.log, body.data.client_message_id);

    // Le cerveau (ai/decideur.ts) comprend le message : lancé MAINTENANT, en
    // parallèle de la conversation, de l'idempotence et de la recherche
    // catalogue. Il lit aussi le dernier message de Tovo : « Yantala. »
    // répond peut-être à « Où récupérer le colis ? ».
    // AIGUILLAGE=cascade : l'ancien aiguillage (classifieur local + Jev).
    const cerveau = Boolean(body.data.text) && cerveauActif();
    // L'application sait montrer un trajet entre deux lieux et porter la
    // consigne jusqu'au livreur (contrat 2, 09/10). Une ancienne version
    // garde la protection : aucune carte qui contredit le trajet demandé.
    const trajetLibre = Number(request.headers['x-tovo-contract']) >= 2;
    // En même temps : le dernier message de Tovo, et les phrases validées de
    // la banque les plus proches (ai/banc/exemples.ts, ~20 ms, sans réseau).
    // LA MÉMOIRE DE CONVERSATION (étape 4, 09/10) : la course ou le repas en
    // cours, et la dernière liste affichée, relus dans les derniers messages
    // (ai/conversation.ts). Au-delà de 6 heures, plus rien ne compte.
    const sansMemoire: Memoire = { tache: null, ecran: null };
    const memoire: Promise<Memoire> = body.data.conversation_id
      ? lignesRecentes(db, body.data.conversation_id).then((l) => lireConversation(l)).catch(() => sansMemoire)
      : Promise.resolve(sansMemoire);
    const decisionCerveau = cerveau
      ? Promise.all([
        dernierMessageTovo(db, body.data.conversation_id).catch(() => null),
        etatDuParcours(db, body.data.conversation_id),
        env.CERVEAU_EXEMPLES === 'oui' ? exemplesPour(body.data.text!).catch(() => []) : Promise.resolve([]),
        memoire,
      ])
        .then(([avant, etat, exemples, m]) => comprendre(body.data.text!, {
          avant, etat: [decrireMemoire(m), etat].filter(Boolean).join(' '), exemples,
        }))
        .catch(() => null)
      : Promise.resolve(null);
    const decisionCascade = body.data.text && !cerveau && cascadeActive()
      ? aiguiller(body.data.text).catch(() => null)
      : Promise.resolve(null);

    // Et la recherche catalogue EN MÊME TEMPS. « du riz », « coca » : si elle
    // trouve exactement, on répond sans attendre Jev — c'est le cas le plus
    // courant, et Jev y ajoutait près d'une seconde. Seulement pour une
    // recherche évidente (pas « annule », « le deuxième », « comme d'habitude »).
    const textePourRecherche = body.data.text ?? '';
    const recherchePrealable = (cerveau || cascadeActive()) && textePourRecherche
      && !referenceAuxResultats(textePourRecherche) && !demandeDeCommandePassee(textePourRecherche)
      && rechercheProduitRapide(textePourRecherche, requeteProduitUtilisateur(textePourRecherche))
      ? cataloguePage(db, { q: requeteProduitUtilisateur(textePourRecherche), limit: 8 }, false).catch(() => null)
      : Promise.resolve(null);

    const output = chatStream(reply, streaming);
    const started = performance.now();
    let firstResultMs: number | undefined;
    let firstTextMs: number | undefined;
    const emit = (event: Record<string, unknown>) => {
      const elapsed = Math.round(performance.now() - started);
      if (event.type === 'results' && firstResultMs === undefined) firstResultMs = elapsed;
      if (event.type === 'text' && firstTextMs === undefined) firstTextMs = elapsed;
      output.emit(event);
    };

    // Conversation : celle fournie, ou une nouvelle. La RLS garantit qu'on
    // ne peut pas écrire dans celle d'un autre.
    let conversationId = body.data.conversation_id;
    if (!conversationId) {
      const { data, error } = await db
        .from('conversations')
        .insert({ user_id: userId })
        .select('id')
        .single();
      if (error) {
        const failure = toHttpFailure(error);
        return reply.code(failure.status).send(failure.body);
      }
      conversationId = data.id as string;
    }

    // Idempotence : si ce message a déjà été traité, on renvoie la réponse
    // existante sans rappeler le modèle.
    const dejaTraite = await reponseExistante(db, conversationId, body.data.client_message_id);
    if (dejaTraite) return output.finish(dejaTraite);

    // Le message vocal n'a pas de texte : la consigne qui accompagne l'audio
    // dit au modèle quoi en faire, et sert aussi de trace dans l'historique
    // — on ne conserve pas l'enregistrement lui-même.
    const message = body.data.audio
      ? "L'utilisateur a parlé. Écoute l'enregistrement et traite sa demande comme s'il l'avait écrite."
        : body.data.text
          ? body.data.text
          : interactionEnMessage(body.data.interaction!.action, body.data.interaction!.payload);

    // Ces interactions désignent déjà exactement l'opération à effectuer.
    // Les faire interpréter par Gemini ajoutait deux appels séquentiels : un
    // pour choisir l'outil, puis un autre pour reformuler son résultat.
    const actionDirecte = body.data.interaction?.action;
    const outilDirect = actionDirecte === 'search_by_image'
      ? 'rechercher_par_image'
      : actionDirecte === 'compare_price'
        ? 'comparer_prix'
        : null;
    if (outilDirect) {
      const executer = EXECUTORS[outilDirect];
      if (!executer) throw new Error(`outil ${outilDirect} absent`);
      const resultat = await executer(body.data.interaction!.payload, {
        db,
        userId,
        currentMessage: message,
        ...(body.data.context ? { position: body.data.context } : {}),
      });
      const contenu = resultat.content ?? (resultat.components.length > 0
        ? 'Voici ce que je trouve.'
        : "Je n'ai rien trouvé pour le moment.");

      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      emit({ type: 'text', text: contenu });

      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'user',
        content: libelleLisible(actionDirecte!, body.data.interaction!.payload) ?? message,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'assistant',
        content: contenu,
        components: resultat.components,
      });

      request.log.info({
        conversationId,
        action: actionDirecte,
        duration_ms: Math.round(performance.now() - started),
      }, 'interaction traitee sans orchestration');
      return output.finish({
        conversation_id: conversationId,
        ...envelope(contenu, resultat.components),
      });
    }

    // « Oui, annuler » / « Non, la garder » : la réponse au garde-fou
    // d'annulation (tools.ts). Seul ce bouton annule une commande.
    const valeurTuile = body.data.interaction?.action === 'quick_reply'
      ? String(body.data.interaction.payload.value ?? '')
      : '';
    // « Pharmacies de garde près de moi » (carte de l'accueil, ou écrit) :
    // une réponse directe, sans modèle — les plus proches de la position.
    if (body.data.text && demandeDeGarde(body.data.text)) {
      const resultat = await reponseGarde(body.data.context ?? null, HORS_TOVO_OUI);
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      resultat.content = await rediger({ message: body.data.text, prevue: resultat.content, faits: resultat.summary, composants: resultat.components });
      emit({ type: 'text', text: resultat.content });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'user', content: body.data.text,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'assistant', content: resultat.content, components: resultat.components,
      });
      request.log.info({ conversationId, position: Boolean(body.data.context) }, 'pharmacies de garde');
      return output.finish({ conversation_id: conversationId, ...envelope(resultat.content, resultat.components) });
    }

    // « Oui, envoyez un livreur » / « Non, voir ce que Tovo propose » : la
    // réponse à une enseigne hors Tovo (catalogue.ts, enseigneHorsTovo).
    if (valeurTuile.startsWith(HORS_TOVO_OUI) || valeurTuile.startsWith(HORS_TOVO_NON)) {
      const resultat = await reponseHorsTovo(db, valeurTuile);
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      emit({ type: 'text', text: resultat.content });
      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'user',
        content: libelleLisible('quick_reply', body.data.interaction!.payload) ?? message,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'assistant', content: resultat.content, components: resultat.components,
      });
      request.log.info({ conversationId, oui: valeurTuile.startsWith(HORS_TOVO_OUI) }, 'enseigne hors Tovo');
      return output.finish({ conversation_id: conversationId, ...envelope(resultat.content, resultat.components) });
    }

    if (valeurTuile.startsWith(ANNULER_CONFIRME) || valeurTuile === GARDER_COMMANDE) {
      const resultat = valeurTuile === GARDER_COMMANDE
        ? { components: [], content: 'D’accord, votre commande continue.' }
        : await annulerConfirme({ db, userId }, valeurTuile.slice(ANNULER_CONFIRME.length));
      const contenu = resultat.content ?? 'C’est noté.';
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      emit({ type: 'text', text: contenu });
      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'user',
        content: libelleLisible('quick_reply', body.data.interaction!.payload) ?? message,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'assistant', content: contenu, components: resultat.components,
      });
      request.log.info({ conversationId, annulee: valeurTuile !== GARDER_COMMANDE }, 'confirmation d’annulation');
      return output.finish({ conversation_id: conversationId, ...envelope(contenu, resultat.components) });
    }

    // --- Aiguillage -------------------------------------------------------
    // Une tuile touchée porte l'intention CHOISIE et la phrase d'origine ;
    // sinon Jev propose une route, ou des tuiles s'il hésite sur une action.
    const choisie = intentionChoisie(body.data.interaction);
    const texteClient = choisie?.message ?? body.data.text;
    // Ce que le client relit : sa phrase, ou le libellé de la tuile touchée.
    const contenuClient = body.data.text
      ?? (body.data.interaction ? libelleLisible(body.data.interaction.action, body.data.interaction.payload) : null)
      ?? message;
    let intention: Intention | 'modele' | undefined = choisie?.intention;
    // Ce que le client cherche, selon le cerveau (« merguez »).
    let requeteCerveau: string | undefined;
    let rayonCerveau: Rayon | undefined;
    let suiteCerveau = false;
    let commerceCerveau: TypeCommerceCherche | undefined;
    let detailsCerveau: Details | undefined;
    let lieuCerveau: string | undefined;
    // Le rédacteur (ai/redacteur.ts) : chaque réponse directe à un message du
    // client est mise en mots par une IA, à partir de ce qu'il a VRAIMENT dit.
    // Les cartes partent d'abord ; la phrase suit.
    const enMots = (prevue: string, faits: unknown, composants: Component[]) => (texteClient
      ? rediger({ message: texteClient, prevue, faits, composants })
      : Promise.resolve(prevue));
    let pageInitiale: CataloguePage | undefined;

    // Produit trouvé exactement : sans cerveau (mode cascade), la route est
    // évidente. Avec le cerveau, il décide TOUJOURS (article 1 de la
    // constitution : un seul interprète) — « d'autres merguez » trouvait des
    // merguez par les mots et perdait « d'autres » (article 7). Sa recherche
    // faite en parallèle sert quand même, s'il est d'accord (plus bas).
    const prealable = choisie ? null : await recherchePrealable;
    if (!cerveau && prealable && prealable.match_type === 'exact' && prealable.total > 0) {
      intention = 'recherche';
      pageInitiale = prealable;
      request.log.info({ ref: body.data.client_message_id }, 'recherche exacte : réponse sans attendre Jev');
    }

    if (!choisie && !pageInitiale && body.data.text) {
      let route: Route;
      if (cerveau) {
        const d = await decisionCerveau;
        // Article 3 : on ne propose d'agir que sur ce qui existe.
        route = d ? routeDuCerveau(d, body.data.text, { commande: await commandeEnCours(db) }) : { type: 'habituel', decision: null };
        // Une course est déjà ouverte : redemander un livreur ne fait que la
        // remontrer (la carte, sans commande) — rien à faire confirmer (M8).
        if (route.type === 'clarifier' && (d?.intention === 'livreur' || d?.intention === 'colis')
          && (await memoire).tache?.genre === 'course') {
          route = { type: 'intention', intention: d.intention, decision: route.decision };
        }
        requeteCerveau = d?.produit || undefined;
        rayonCerveau = d?.rayon;
        suiteCerveau = d?.suite === true;
        commerceCerveau = d?.commerce;
        detailsCerveau = d?.details;
        lieuCerveau = d?.lieu;
        request.log.info({
          ref: body.data.client_message_id,
          intention: d?.intention ?? null,
          sur: d?.sur ?? null,
          modele: d?.modele ?? null,
          ms: d ? Math.round(d.ms) : null,
          relance: d?.relance ?? false,
          ...(d?.erreurs.length ? { erreurs: d.erreurs } : {}),
          route: route.type,
        }, 'cerveau');
      } else {
        const cascade = await decisionCascade;
        route = cascade?.route ?? decider(null, body.data.text);
        if (cascade) {
          const resume = (d: typeof cascade.local) => d && {
            choix: d.choix, confiance: Number(d.confiance.toFixed(2)), ms: Math.round(d.ms),
            ...(d.erreur ? { erreur: d.erreur } : {}),
          };
          request.log.info({
            ref: body.data.client_message_id,
            source: cascade.source,
            local: resume(cascade.local),
            jev: resume(cascade.jev),
            route: route.type,
          }, 'aiguillage');
        }
      }
      if (route.type === 'intention') intention = route.intention;
      // Une recherche : celle faite en parallèle du cerveau (suggestions
      // proches comprises) sert telle quelle, sans la refaire.
      if (intention === 'recherche' && prealable && !rayonCerveau && !suiteCerveau && !commerceCerveau && !detailsCerveau?.precision
        && (!requeteCerveau || requeteProduitUtilisateur(requeteCerveau) === requeteProduitUtilisateur(body.data.text ?? ''))) {
        pageInitiale = prealable;
      }

      if (route.type === 'clarifier') {
        // Proposer ce qu'on a compris plutôt que deviner : une action mal
        // devinée fait déplacer un livreur ou annule une commande.
        emit({ type: 'conversation', conversation_id: conversationId });
        emit({ type: 'results', components: route.components });
        route.contenu = await enMots(route.contenu, null, route.components);
        emit({ type: 'text', text: route.contenu });
        await db.from('messages').insert({
          conversation_id: conversationId,
          role: 'user',
          content: body.data.text,
          client_message_id: body.data.client_message_id,
        });
        await db.from('messages').insert({
          conversation_id: conversationId,
          role: 'assistant',
          content: route.contenu,
          components: route.components,
        });
        return output.finish({ conversation_id: conversationId, ...envelope(route.contenu, route.components) });
      }
    }
    // Route connue : les détecteurs à mots ne décident plus.
    const parJev = intention !== undefined;
    // Le cerveau n'a pas pu trancher (panne, délai) : les détecteurs à mots
    // ne déclenchent plus d'action coûteuse à sa place — « Je veux devenir
    // livreur » ne doit jamais commander de livreur parce qu'il contient le mot.
    const motsPermis = !cerveau;

    // « Je veux un livreur » (décision D1 du 02/10, docs/PARCOURS-CLIENTS.md) :
    // la course ne part JAMAIS sur une phrase. Une erreur de compréhension ne
    // doit pas faire déplacer un livreur, et le client voit le prix avant. La
    // carte pré-remplie s'affiche plus bas ; il touche « Commander le livreur ».
    // Seule exception gardée : une course déjà en route est montrée, au lieu
    // d'en préparer une seconde.
    if (texteClient && (parJev ? intention === 'livreur' : motsPermis && demandeUnLivreur(texteClient))) {
      const deja = await courseDejaEnRoute(db);
      if (deja) {
        emit({ type: 'conversation', conversation_id: conversationId });
        emit({ type: 'results', components: deja.components });
        deja.content = await enMots(deja.content, null, deja.components);
        emit({ type: 'text', text: deja.content });
        await db.from('messages').insert({
          conversation_id: conversationId, role: 'user', content: contenuClient, client_message_id: body.data.client_message_id,
        });
        await db.from('messages').insert({
          conversation_id: conversationId, role: 'assistant', content: deja.content, components: deja.components,
        });
        return output.finish({ conversation_id: conversationId, ...deja });
      }
    }

    // Un envoi de colis n'a rien à interpréter : il ouvre toujours la même
    // carte. Le laisser au modèle lui faisait parfois appeler
    // `mes_adresses`, puis traiter le choix comme une livraison de panier.
    // C'est ainsi que « Livrer à Harobanda » finissait par « panier vide ».
    // Avec des détails (« à Moussa, 90 12 34 56, Harobanda »), c'est le modèle
    // qui ouvre la carte : lui seul sait la pré-remplir. La voie rapide
    // l'ouvrait vide et le client retapait ce qu'il venait de dire.
    // Sans cerveau (panne), l'ancien repère à mots : des détails → le modèle.
    // Avec le cerveau, ses précisions remplissent la carte (article 9).
    const detailsDeColis = !parJev && texteClient ? /\d{2}\s?\d{2}\s?\d{2}|\b(à|a|chez|pour)\s+\p{Lu}/u.test(texteClient) : false;
    // « Va chercher un colis chez Moussa au 90 12 34 56 » : les détails sont
    // extraits sans modèle (lieu, numéro), la voie rapide suffit.
    const recuperation = texteClient ? demandeDeRecuperation(texteClient) : false;
    // Une course est en cours (sa carte n'est pas commandée) : un lieu, un
    // numéro, ou une nouvelle demande de livreur la COMPLÈTE — même après une
    // question entre deux (S1, S2). Ce que le client redit remplace l'ancien.
    const memoireLue = await memoire;
    const courseEnCours = memoireLue.tache?.genre === 'course' ? memoireLue.tache.course : null;
    const ditPourLaCourse = Boolean(detailsCerveau?.depart || detailsCerveau?.arrivee || detailsCerveau?.telephone);
    const suiteDeCourse = Boolean(texteClient && courseEnCours && parJev
      && (intention === 'colis' || intention === 'livreur' || ditPourLaCourse));
    if (texteClient && (suiteDeCourse || ((!detailsDeColis || recuperation) && (parJev
      ? intention === 'colis' || intention === 'livreur'
      : demandeUnColis(texteClient) || demandeUnLivreur(texteClient))))) {
      const executer = EXECUTORS['preparer_course'];
      if (!executer) throw new Error('outil preparer_course absent');

      const resultat = await executer(
        courseEnCours ? argumentsDeLaCourse(completerCourse(courseEnCours, detailsCerveau ?? {})) : argumentsDeCourse(detailsCerveau),
        {
          db,
          userId,
          currentMessage: texteClient,
          ...(body.data.context ? { position: body.data.context } : {}),
          trajetLibre,
        },
      );
      // Plus de carte qui commande d'elle-même (« auto ») : décision D1, la
      // course part au toucher de « Commander le livreur », prix affiché.
      // La carte prend la position d'elle-même : plus de « Touchez Ma
      // position », qui restait affiché même une fois le livreur demandé.
      // Article 4 : rien ne bouge avant le toucher — la phrase le dit.
      // Pas de carte (un trajet qu'elle ne sait pas montrer, 09/10) : aucune
      // course n'est annoncée, seulement les deux choix proposés.
      const sansCarte = !resultat.components.some((c) => c.type === 'courier_form');
      // Une phrase courte et courtoise : la carte dit le reste (V6, 09/10).
      const prevue = sansCarte
        ? 'Je ne peux pas encore préparer une course d’un endroit à un autre sans passer par vous. Choisissez une des deux possibilités ci-dessous.'
        : 'Avec plaisir, voici votre course.';

      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      const contenu = await enMots(prevue, resultat.summary, resultat.components);
      emit({ type: 'text', text: contenu });

      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'user',
        content: contenuClient,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'assistant',
        content: contenu,
        components: resultat.components,
      });

      request.log.info({ conversationId }, 'formulaire colis ouvert sans interprétation');
      return output.finish({
        conversation_id: conversationId,
        ...envelope(contenu, resultat.components),
      });
    }

    // « Annule ma commande » : la carte de la commande et « Oui, annuler » /
    // « Non, la garder », sans passer par le modèle. Rien n'est annulé ici.
    if (intention === 'annuler') {
      const resultat = await EXECUTORS['annuler_commande']!({}, { db, userId, currentMessage: texteClient });
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      const contenu = await enMots(resultat.content ?? 'Voulez-vous vraiment annuler cette commande ?', resultat.summary, resultat.components);
      emit({ type: 'text', text: contenu });
      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'user',
        content: contenuClient,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'assistant', content: contenu, components: resultat.components,
      });
      request.log.info({ conversationId }, 'annulation : confirmation demandée');
      return output.finish({ conversation_id: conversationId, ...envelope(contenu, resultat.components) });
    }

    // « On m'a livré du poulet au lieu du poisson », « le paiement Nita est
    // bloqué » : des excuses claires, la commande concernée, et le problème
    // remonte à l'admin (table signalements). Pas de modèle : il n'y a rien à
    // interpréter, et surtout rien à promettre à la place de l'équipe.
    if (intention === 'aide' && texteClient) {
      const depuis48h = new Date(Date.now() - 48 * 3_600_000).toISOString();
      const { data: recentes } = await db.from('orders').select('id').gte('placed_at', depuis48h)
        .order('placed_at', { ascending: false }).limit(1);
      const orderId = (recentes?.[0]?.id as string | undefined) ?? null;
      const suivi = orderId ? await db.rpc('order_tracking', { p_order_id: orderId }) : null;
      const composants: Component[] = suivi?.data ? [orderTracking(suivi.data as Record<string, unknown>)] : [];
      const { error: erreurSignalement } = await serviceClient().from('signalements').insert({
        user_id: userId, conversation_id: conversationId, order_id: orderId, message: texteClient.slice(0, 2000),
      });
      if (erreurSignalement) {
        request.log.error({ erreur: erreurSignalement.message }, 'signalement impossible (migration 0067 appliquée ?)');
      }
      const prevue = erreurSignalement
        ? 'Désolé pour ce souci. Je n’arrive pas à le transmettre pour le moment : réessayez dans un instant.'
        : `Désolé pour ce souci. Je l’ai transmis à l’équipe Tovo, qui va s’en occuper.${orderId ? ' Voici la commande concernée.' : ''}`;
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: composants });
      const signalement = { signale: !erreurSignalement, commande_concernee: Boolean(orderId) };
      const contenu = await enMots(prevue, erreurSignalement ? signalement : avecPreuves(signalement, 'signalement_transmis'), composants);
      emit({ type: 'text', text: contenu });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'user', content: contenuClient, client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'assistant', content: contenu, components: composants,
      });
      request.log.info({ conversationId, orderId, signale: !erreurSignalement }, 'aide : problème signalé');
      return output.finish({ conversation_id: conversationId, ...envelope(contenu, composants) });
    }

    // « Où est mon panier ? », « je veux payer » : le panier, sans modèle.
    if (intention === 'panier') {
      const resultat = await EXECUTORS['voir_panier']!({}, {
        db, userId, currentMessage: texteClient, ...(body.data.context ? { position: body.data.context } : {}),
      });
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      const contenu = await enMots(resultat.components.length > 0 ? 'Voici votre panier.' : 'Votre panier est vide pour le moment.', resultat.summary, resultat.components);
      emit({ type: 'text', text: contenu });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'user', content: contenuClient, client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId, role: 'assistant', content: contenu, components: resultat.components,
      });
      return output.finish({ conversation_id: conversationId, ...envelope(contenu, resultat.components) });
    }

    // « Je veux manger » n'est ni une recherche de proximité, ni une
    // recherche du produit nommé « manger ». On ouvre directement la porte
    // Restaurants, classée par ouverture et qualité, sans mélanger marché,
    // électronique, beauté ou pharmacie.
    if (texteClient && demandeGeneraleDeRepas(texteClient) && (!parJev || intention === 'envie')) {
      const executer = EXECUTORS['lister_restaurants'];
      if (!executer) throw new Error('outil lister_restaurants absent');

      const resultat = await executer(
        {},
        {
          db,
          userId,
          currentMessage: texteClient,
          position: body.data.context,
        },
      );
      emit({ type: 'conversation', conversation_id: conversationId });
      emit({ type: 'results', components: resultat.components });
      const contenu = await enMots(
        'Avec plaisir. Voici les **restaurants** disponibles — choisissez celui qui vous fait envie.',
        resultat.summary, resultat.components);
      emit({ type: 'text', text: contenu });

      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'user',
        content: contenuClient,
        client_message_id: body.data.client_message_id,
      });
      await db.from('messages').insert({
        conversation_id: conversationId,
        role: 'assistant',
        content: contenu,
        components: resultat.components,
      });

      request.log.info({ conversationId }, 'restaurants ouverts sans recherche de proximite');
      return output.finish({
        conversation_id: conversationId,
        ...envelope(contenu, resultat.components),
      });
    }

    if (!llmEnabled) {
      return reply.code(503).send({
        error: "L'assistant n'est pas encore configuré.",
        code: 'LLM_DISABLED',
      });
    }

    try {
      // Ce que le client relira. Le vocal n'a pas de texte du tout, et la
      // photo n'a qu'un chemin de fichier : sans ce libellé, l'historique se
      // remplissait de consignes techniques.
      const messagePublic = body.data.audio
        ? '🎤 Message vocal'
        : body.data.interaction
          ? libelleLisible(body.data.interaction.action, body.data.interaction.payload)
          // Texte aiguillé : l'indication donnée au modèle ne doit pas
          // apparaître dans la bulle du client.
          : intention && intention !== 'modele' ? body.data.text ?? null : null;

      // La phrase d'origine (celle d'avant la tuile), plus la route connue.
      const note = intention && intention !== 'modele' ? indication(intention) : null;
      const messageModele = texteClient && intention
        ? note ? `${texteClient}\n${note}` : texteClient
        : message;

      // « Une friperie vers Yantala » : le lieu DIT remplace la position du
      // client pour chercher (article 9 : ce qu'il précise est gardé). Pour
      // une recherche seulement : une course a son départ et son arrivée.
      const situe = lieuCerveau && (intention === 'recherche' || intention === 'boutique' || intention === 'envie' || commerceCerveau)
        ? reperer(lieuCerveau) : null;
      // Un quartier mal transcrit (« vers Gobien » pour Bobiel, 10/10) : le
      // nom connu le plus proche, s'il est le seul aussi proche.
      const approche = situe && !situe.point && lieuCerveau ? quartierApproche(lieuCerveau) : null;
      const autour = situe?.point && situe.description
        ? { point: situe.point, nom: situe.description }
        : approche ? { point: { lat: approche.lat, lng: approche.lng }, nom: approche.nom } : null;
      if (lieuCerveau) request.log.info({ ref: body.data.client_message_id, lieu: lieuCerveau, situe: autour?.nom ?? null }, 'lieu de recherche');

      // Un repas en cours chez une boutique (S10) : un produit demandé se
      // cherche d'abord CHEZ ELLE (« et un coca » chez O'Takoss).
      const repas = memoireLue.tache?.genre === 'repas' ? memoireLue.tache.boutique : null;
      // « et un coca » est parfois lu comme une désignation : ce n'en est une
      // que s'il désigne ce qui est affiché (« le premier », « celui-là »).
      const designeVraiment = intention === 'designe' && Boolean(texteClient && referenceAuxResultats(texteClient));
      if (repas && !designeVraiment && (intention === 'recherche' || intention === 'boutique' || intention === 'envie' || intention === 'designe')) {
        // Ce qu'il cherche, sans le nom de la boutique (« coca O'Takoss » → « coca »).
        const nomBoutique = new Set(normaliserIntention(repas.nom).split(' '));
        const q = normaliserIntention(requeteCerveau ?? texteClient ?? '').split(' ')
          .filter((m) => m && !nomBoutique.has(m)).join(' ');
        const chezElle = q
          ? await cataloguePage(db, { q, merchant_ids: [repas.id], limit: 8 }, false).catch(() => null)
          : null;
        if (chezElle && chezElle.total > 0 && chezElle.match_type !== 'similar') {
          intention = 'recherche';
          requeteCerveau = q;
          pageInitiale = chezElle;
        }
      }

      output.emit({ type: 'conversation', conversation_id: conversationId });
      const resultat = await orchestrate({
        db,
        userId,
        conversationId,
        message: messageModele,
        ...(intention ? { intention } : {}),
        ...(requeteCerveau ? { requete: requeteCerveau } : {}),
        ...(rayonCerveau ? { rayon: rayonCerveau } : {}),
        ...(suiteCerveau ? { suite: true } : {}),
        ...(commerceCerveau ? { commerce: commerceCerveau } : {}),
        ...(detailsCerveau?.precision ? { precision: detailsCerveau.precision } : {}),
        ...(pageInitiale ? { pageInitiale } : {}),
        ...(messagePublic ? { messagePublic } : {}),
        clientMessageId: body.data.client_message_id,
        ...(body.data.audio ? { audio: body.data.audio } : {}),
        // Chercher autour du lieu dit, mesurer depuis le client (07/10).
        position: autour ? { ...autour.point, depuis: body.data.context ?? null } : body.data.context,
        ...(autour ? { autourDe: autour.nom } : {}),
        ...(streaming ? { onEvent: emit } : {}),
        trajetLibre,
      });

      if (resultat.rejected.length > 0) {
        // Un composant rejeté signifie que le modèle a inventé un
        // identifiant. C'est rattrapé, mais ça doit se voir.
        request.log.warn(
          { rejected: resultat.rejected, conversationId },
          'composants rejetés par le validateur',
        );
        // Rien n'a planté, mais une hausse de ces rejets signale un prompt
        // qui dérive — une dérive qu'on ne voit jamais sans la mesurer.
        signaler('composants rejetés par le validateur', {
          rejets: resultat.rejected,
          modele: resultat.usage,
        });
      }

      if (resultat.inventions?.length) {
        // Le modèle a affirmé un prix, une durée ou un nom absent de la
        // base : la phrase a été retirée avant d'être vue. Ces lignes
        // alimentent le banc (npm run banc:recolter).
        request.log.warn(
          { ref: body.data.client_message_id, message: texteClient ?? message, inventions: resultat.inventions },
          'invention bloquée',
        );
      }

      request.log.info(
        { usage: resultat.usage, conversationId, duration_ms: Math.round(performance.now() - started),
          first_result_ms: firstResultMs, first_text_ms: firstTextMs },
        'tour de conversation',
      );

      return output.finish({
        conversation_id: conversationId,
        content: resultat.content,
        components: resultat.components,
        contract_version: resultat.contract_version,
      });
    } catch (cause) {
      if (cause instanceof ChatUnavailableError || cause instanceof LlmUnavailableError) {
        request.log.error({ cause: cause.message }, 'assistant indisponible');
        return output.finish(
          { ...envelope(
            "Je n'arrive pas à répondre pour le moment. Choisissez une catégorie en attendant.",
          ) }, 503,
        );
      }
      request.log.error({ cause }, 'conversation interrompue');
      return output.finish({ error: 'La réponse a été interrompue. Retrouvez la conversation dans votre historique.' }, 503);
    }
  });
}

/**
 * Le dernier message de Tovo dans la conversation, pour que le cerveau sache
 * à quoi le client répond. `null` pour une conversation neuve.
 */
/**
 * Les précisions du cerveau (article 9) → les arguments de preparer_course :
 * un lieu où prendre quelque chose = « récupérer » ; sinon un lieu où
 * l'apporter = « déposer ». Le numéro va au contact de l'endroit concerné.
 */
function argumentsDeCourse(d: Details | undefined): Record<string, unknown> {
  if (!d) return {};
  // Départ ET arrivée, quand le client a dit les deux (09/10, S4) :
  // preparer_course juge si la carte peut les montrer. Et la consigne, qu'il
  // ne doit jamais dire transmise sans place pour elle.
  const consigne = d.precision ? { consigne: d.precision } : {};
  if (d.depart) {
    return {
      mode: 'recuperer', ou_recuperer: d.depart,
      ...(d.arrivee ? { arrivee: { hint: d.arrivee } } : {}),
      ...(d.telephone ? { contact_sur_place: d.telephone } : {}),
      ...consigne,
    };
  }
  if (d.arrivee) {
    return { mode: 'deposer', arrivee: { hint: d.arrivee }, ...(d.telephone ? { destinataire: d.telephone } : {}), ...consigne };
  }
  return { ...(d.telephone ? { destinataire: d.telephone } : {}), ...consigne };
}

async function dernierMessageTovo(
  db: import('@supabase/supabase-js').SupabaseClient,
  conversationId: string | undefined,
): Promise<string | null> {
  if (!conversationId) return null;
  const { data } = await db
    .from('messages')
    .select('content, created_at')
    .eq('conversation_id', conversationId)
    .eq('role', 'assistant')
    .order('created_at', { ascending: false })
    .limit(1);
  const dernier = data?.[0] as { content?: string; created_at?: string } | undefined;
  // Plus de 6 heures : il ne compte plus (décision E2, S8).
  if (!dernier || Date.now() - Date.parse(dernier.created_at ?? '') > DUREE_DE_VIE_MS) return null;
  return dernier.content ?? null;
}

/** Les derniers messages, du plus récent au plus ancien : la mémoire s'y relit. */
async function lignesRecentes(
  db: import('@supabase/supabase-js').SupabaseClient,
  conversationId: string,
): Promise<Ligne[]> {
  const { data } = await db
    .from('messages')
    .select('role, content, components, created_at')
    .eq('conversation_id', conversationId)
    .in('role', ['user', 'assistant'])
    .order('created_at', { ascending: false })
    .limit(12);
  return (data ?? []) as Ligne[];
}

/**
 * Réponse déjà produite pour ce `client_message_id`, s'il y en a une.
 *
 * On repère le message utilisateur puis la réponse qui le suit. Sans ce
 * contrôle, un rejeu réseau relancerait le modèle et facturerait deux fois
 * la même question.
 */
async function reponseExistante(
  db: import('@supabase/supabase-js').SupabaseClient,
  conversationId: string,
  clientMessageId: string,
) {
  const { data } = await db
    .from('messages')
    .select('id, created_at')
    .eq('conversation_id', conversationId)
    .eq('client_message_id', clientMessageId)
    .limit(1);

  const question = data?.[0];
  if (!question) return null;

  // Le message utilisateur existe : la réponse est celle qui le suit
  // immédiatement dans la conversation.
  const { data: suite } = await db
    .from('messages')
    .select('content, components')
    .eq('conversation_id', conversationId)
    .eq('role', 'assistant')
    .gt('created_at', question.created_at as string)
    .order('created_at', { ascending: true })
    .limit(1);

  const message = suite?.[0];
  if (!message) return null;

  return {
    conversation_id: conversationId,
    content: message.content as string,
    components: message.components as unknown[],
    contract_version: 1,
  };
}
