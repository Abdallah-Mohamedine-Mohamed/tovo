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

const chatSchema = z
  .object({
    conversation_id: z.string().uuid().optional(),
    client_message_id: z.string().uuid(),
    text: z.string().min(1).max(2000).optional(),
    interaction: interactionSchema.optional(),
    context: z
      .object({
        lat: z.number().min(-90).max(90),
        lng: z.number().min(-180).max(180),
      })
      .optional(),
  })
  .refine((v) => Boolean(v.text) !== Boolean(v.interaction), {
    message: 'fournir « text » OU « interaction », pas les deux',
  });

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

    const message = body.data.text
      ? body.data.text
      : interactionEnMessage(body.data.interaction!.action, body.data.interaction!.payload);

    try {
      const resultat = await orchestrate({
        db,
        userId,
        conversationId,
        message,
        clientMessageId: body.data.client_message_id,
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
