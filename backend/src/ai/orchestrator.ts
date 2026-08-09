import type { SupabaseClient } from '@supabase/supabase-js';
import { llmClient, LlmUnavailableError, type LlmTurn } from './llmClient.js';
import { SYSTEM_PROMPT, contexteUtilisateur } from './systemPrompt.js';
import { EXECUTORS, TOOL_DEFINITIONS, type ToolContext } from './tools.js';
import { collectIds, sanitizeToolResult, validateComponents } from './validate.js';
import { envelope, type ChatEnvelope, type Component } from '../components/builders.js';

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
}

export interface OrchestrateOutput extends ChatEnvelope {
  messageId: string | null;
  /** Rejets du validateur — un pic signale un prompt qui dérive. */
  rejected: string[];
  usage: { input: number; output: number; cached: number; cycles: number };
}

export class ChatUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ChatUnavailableError';
  }
}

export async function orchestrate(input: OrchestrateInput): Promise<OrchestrateOutput> {
  const client = llmClient();
  if (!client) {
    throw new ChatUnavailableError(
      "L'assistant n'est pas disponible pour le moment.",
    );
  }

  const ctx: ToolContext = {
    db: input.db,
    userId: input.userId,
    position: input.position,
  };

  const history = await chargerHistorique(input.db, input.conversationId);

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
  let texteFinal = '';
  let entree = 0;
  let sortie = 0;
  let misEnCache = 0;
  let cycles = 0;

  for (; cycles < MAX_CYCLES; cycles++) {
    const dernierCycle = cycles === MAX_CYCLES - 1;

    const reponse = await client.generate({
      system: SYSTEM_PROMPT,
      history,
      // Au dernier cycle, plus d'outils : le modèle doit conclure.
      tools: dernierCycle ? [] : TOOL_DEFINITIONS,
    });

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
          content: JSON.stringify({ erreur: `outil inconnu : ${appel.name}` }),
        });
        continue;
      }

      try {
        const resultat = await executeur(appel.args, ctx);

        // Les identifiants viennent d'ici, et de nulle part ailleurs.
        collectIds(resultat.summary, idsAutorises);
        for (const composant of resultat.components) {
          collectIds(composant.data, idsAutorises);
        }

        composantsDuTour.push(...resultat.components);

        history.push({
          role: 'tool',
          toolName: appel.name,
          // Le texte des boutiquiers passe par le neutraliseur avant
          // d'entrer dans le contexte du modèle.
          content: JSON.stringify(sanitizeToolResult(resultat.summary)),
        });
      } catch (cause) {
        history.push({
          role: 'tool',
          toolName: appel.name,
          content: JSON.stringify({
            erreur: cause instanceof Error ? cause.message : 'échec',
          }),
        });
      }
    }
  }

  const { components, rejected } = validateComponents(composantsDuTour, idsAutorises);

  if (!texteFinal && components.length === 0) {
    texteFinal = "Je n'ai pas trouvé ce que vous cherchez. Reformulez, ou choisissez une catégorie.";
  }

  const messageId = await persister(input, texteFinal, components);

  return {
    ...envelope(texteFinal, components),
    messageId,
    rejected,
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
): Promise<LlmTurn[]> {
  const { data } = await db
    .from('messages')
    .select('role, content')
    .eq('conversation_id', conversationId)
    .in('role', ['user', 'assistant'])
    .order('created_at', { ascending: false })
    .limit(HISTORIQUE);

  return (data ?? [])
    .reverse()
    .map((m) => ({
      role: m.role === 'assistant' ? ('model' as const) : ('user' as const),
      content: (m.content as string) ?? '',
    }))
    .filter((t) => t.content.length > 0);
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
