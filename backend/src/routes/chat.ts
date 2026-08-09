import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';
import { ChatUnavailableError, orchestrate } from '../ai/orchestrator.js';
import { LlmUnavailableError, llmEnabled } from '../ai/llmClient.js';
import { signaler } from '../lib/observability.js';

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
      return `J'ai envoyé une photo, cherche ce produit. image_path : ${payload.image_path}`;
    case 'compare_price':
      return `Compare les prix pour : ${payload.query}.`;
    case 'quick_reply':
      return String(payload.label ?? payload.value ?? '');
    default:
      return `Action : ${action} ${JSON.stringify(payload)}`;
  }
}

export async function chatRoutes(app: FastifyInstance): Promise<void> {
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
    if (!llmEnabled) {
      return reply.code(503).send({
        error: "L'assistant n'est pas encore configuré.",
        code: 'LLM_DISABLED',
      });
    }

    const body = chatSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const db = request.supabase!;
    const userId = request.user!.id;

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
    if (dejaTraite) return reply.send(dejaTraite);

    // Le message vocal n'a pas de texte : la consigne qui accompagne l'audio
    // dit au modèle quoi en faire, et sert aussi de trace dans l'historique
    // — on ne conserve pas l'enregistrement lui-même.
    const message = body.data.audio
      ? "L'utilisateur a parlé. Écoute l'enregistrement et traite sa demande comme s'il l'avait écrite."
      : body.data.text
        ? body.data.text
        : interactionEnMessage(body.data.interaction!.action, body.data.interaction!.payload);

    try {
      const resultat = await orchestrate({
        db,
        userId,
        conversationId,
        message,
        clientMessageId: body.data.client_message_id,
        ...(body.data.audio ? { audio: body.data.audio } : {}),
        position: body.data.context,
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

      request.log.info(
        { usage: resultat.usage, conversationId },
        'tour de conversation',
      );

      return reply.send({
        conversation_id: conversationId,
        content: resultat.content,
        components: resultat.components,
        contract_version: resultat.contract_version,
      });
    } catch (cause) {
      if (cause instanceof ChatUnavailableError || cause instanceof LlmUnavailableError) {
        request.log.error({ cause: cause.message }, 'assistant indisponible');
        return reply.code(503).send(
          envelope(
            "Je n'arrive pas à répondre pour le moment. Choisissez une catégorie en attendant.",
          ),
        );
      }
      throw cause;
    }
  });
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
