import { z } from 'zod';

/**
 * Validation de l'environnement au démarrage.
 *
 * Le process refuse de démarrer si une variable requise manque, plutôt que de
 * planter à la première requête en production. Les variables des phases
 * suivantes (IA, paiement) sont optionnelles tant que leur module n'existe pas.
 */
/**
 * Une variable absente et une variable vide veulent dire la même chose.
 *
 * `.optional()` n'accepte que l'absence : une ligne `NITA_BASE_URL=` laissée
 * dans un `.env` ou une variable Railway vidée sans être supprimée devient
 * une chaîne vide, que `.url()` rejette — et le process refuse de démarrer
 * pour une variable qui n'était même pas censée être utilisée.
 */
const vide = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess((v) => (v === '' ? undefined : v), schema.optional());

/** Vide = la valeur par défaut (et non une erreur au démarrage). */
const sansVide = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess((v) => (v === '' ? undefined : v), schema);

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),

  SUPABASE_URL: z.string().url(),
  SUPABASE_ANON_KEY: z.string().min(1),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),

  // Optionnel en développement : tant que le backend n'est pas déployé, il
  // n'y a pas d'URL publique à donner au hook Supabase, donc pas de secret.
  // La route de livraison d'OTP répond alors 503 au lieu de faire semblant.
  // Obligatoire en production, vérifié plus bas.
  AUTH_HOOK_SECRET: z.string().optional(),

  OTP_CHANNEL: z.enum(['whatsapp', 'log']).default('log'),
  WHATSAPP_PHONE_NUMBER_ID: z.string().optional(),
  WHATSAPP_ACCESS_TOKEN: z.string().optional(),
  WHATSAPP_TEMPLATE_NAME: z.string().default('tovo_otp'),
  WHATSAPP_TEMPLATE_LOCALE: z.string().default('fr'),
  /**
   * Bouton du modèle, à accorder avec celui approuvé chez Meta.
   *
   * Un modèle d'authentification porte un bouton « copier le code » ; un
   * modèle utilitaire n'en a généralement aucun. Envoyer un composant bouton
   * à un modèle qui n'en a pas fait échouer l'envoi — et le message n'est
   * jamais parti, donc personne ne se connecte.
   */
  WHATSAPP_TEMPLATE_BUTTON: z.enum(['none', 'copy_code', 'url']).default('none'),
  WHATSAPP_GRAPH_VERSION: z.string().default('v21.0'),

  GEMINI_API_KEY: z.string().optional(),
  // Version explicite, jamais un alias comme `gemini-flash-latest` : un
  // alias change de modèle sans prévenir, et le comportement du function
  // calling se décale un matin sans que rien dans le dépôt ne l'explique.
  GEMINI_MODEL: z.string().default('gemini-3.8-flash'),
  // Les tâches mécaniques (transcription et mots-clés d'une photo) ne
  // doivent pas payer la latence du modèle conversationnel principal.
  GEMINI_FAST_MODEL: z.string().default('gemini-3.5-flash-lite'),

  // Jev (TypeSafe) via OpenRouter, en mode ombre : consulté en arrière-plan
  // sur chaque message, sa décision est JOURNALISÉE mais jamais utilisée.
  // Sert à mesurer, depuis Railway, sa justesse et sa latence réelles.
  OPENROUTER_API_KEY: z.string().optional(),
  JEV_OMBRE: z.enum(['0', '1']).default('0'),
  JEV_MODEL: z.string().default('typesafe/jev-1.13'),
  // Aiguillage RÉEL : Jev choisit la route de chaque message écrit, et fait
  // proposer des tuiles quand il hésite (ai/aiguillage.ts). « 0 » = retour
  // immédiat aux détecteurs à mots, sans redéploiement de code.
  JEV_AIGUILLAGE: z.enum(['0', '1']).default('0'),
  // Au-dessus : Jev décide. En dessous : tuiles, ou chemin habituel.
  JEV_SEUIL: z.coerce.number().min(0).max(1).default(0.8),
  // Au-delà, on n'attend plus Jev : le message suit le chemin habituel.
  // Budget de Jev. Dans la cascade, il n'est consulté que si le classifieur
  // local hésite : au-delà de ce délai, on ne l'attend plus. Mesuré le
  // 23/09 : 0,7 s de médiane certains moments, 4,9 s à d'autres.
  JEV_DELAI_MS: z.coerce.number().int().positive().default(1200),

  // Transcription des notes vocales (services/transcription.ts).
  // Principal : Microsoft MAI-Transcribe-2, le meilleur sur les vraies notes
  // de Niamey (banc du 24/09 : 10-11/11, ~1 s). Par OpenRouter (défaut, le
  // plus rapide mesuré depuis Niamey) ou directement chez Azure.
  TRANSCRIPTION_MAI_VIA: z.enum(['openrouter', 'azure']).default('openrouter'),
  AZURE_SPEECH_KEY: vide(z.string()),
  AZURE_SPEECH_REGION: z.string().default('eastus'),
  // Filet de sécurité : OpenAI gpt-transcribe, lancé seulement si le
  // principal n'a pas répondu dans ce délai, échoue ou rend du vide.
  OPENAI_API_KEY: vide(z.string()),
  // 1,5 s : sous ce seuil, MAI finissait souvent par gagner quand même, et
  // OpenAI était payé pour rien (banc du 24/09, depuis Niamey). À régler sur
  // les temps mesurés depuis Railway (journal « transcription terminee »).
  TRANSCRIPTION_SECOURS_MS: z.coerce.number().int().positive().default(1500),
  // Mode « ombre » : part des notes (0 à 1) ÉGALEMENT envoyées, en
  // arrière-plan, par les DEUX routes vers MAI (OpenRouter et Azure), pour
  // comparer leurs temps sur la même note au même moment. 0 = arrêté.
  // Exige OPENROUTER_API_KEY et AZURE_SPEECH_KEY. Coût : ~0,0002 $ par note.
  TRANSCRIPTION_OMBRE: z.coerce.number().min(0).max(1).default(0),

  // Classifieur d'intentions LOCAL (ai/classifieur.ts) : première marche de
  // la cascade, ~20 ms, sans réseau. Charge ~120 Mo de modèle au démarrage
  // (en arrière-plan) et ~300 Mo de mémoire.
  CLASSIFIEUR_LOCAL: z.enum(['0', '1']).default('0'),
  // Au-dessus : il décide seul. Mesuré avec le double accord (voisins +
  // régression logistique d'accord) : ≥ 0,7 → 57 % des messages, 1 %
  // d'erreur. Sans l'arbitre (index ancien), préférer 0,8.
  CLASSIFIEUR_SEUIL: z.coerce.number().min(0).max(1).default(0.7),

  // Le cerveau (ai/decideur.ts) : Gemini comprend chaque message et décide
  // de la route. Banc du 26/09 (193 phrases) : 94-95 % de justesse, 1 à 2
  // actions coûteuses à tort, contre 6 pour classifieur + Jev.
  // 'cascade' rend la main à l'ancien aiguillage (classifieur local + Jev).
  AIGUILLAGE: sansVide(z.enum(['cerveau', 'cascade']).default('cerveau')),
  // « modèle:réflexion » (réflexion : aucune, courte ou low). Banc du 26/09
  // avec la consigne du cerveau, 0 action coûteuse à tort pour tous :
  //   3.1-flash-lite:aucune  96 %, médiane 0,93 s, 95 % sous 1,27 s ← choisi
  //   3.5-flash-lite:courte  94 %, 0,73 s / 0,89 s
  //   3.8-flash:low          97 %, 1,39 s / 2,65 s
  CERVEAU_MODELE: sansVide(z.string().default('gemini-3.1-flash-lite:aucune')),
  // Relance : si le cerveau n'a pas répondu dans ce délai, un second modèle
  // part en parallèle et la première réponse gagne. Coupe la traîne lente.
  CERVEAU_RELANCE_MS: sansVide(z.coerce.number().int().positive().default(1300)),
  CERVEAU_RELANCE_MODELE: sansVide(z.string().default('gemini-3.5-flash-lite:courte')),
  // Personne n'a répondu dans ce délai : chemin habituel, sans aiguillage.
  CERVEAU_DELAI_MAX_MS: sansVide(z.coerce.number().int().positive().default(4000)),
  // Dernier recours si Google est en panne (exige OPENAI_API_KEY).
  CERVEAU_SECOURS_OPENAI: sansVide(z.string().default('gpt-5.5')),

  REDIS_URL: z.string().optional(),
  SENTRY_DSN: z.string().optional(),
  FCM_SERVICE_ACCOUNT_JSON: z.string().optional(),

  // URL publique de ce backend, telle que Nita doit la rappeler. Sans elle,
  // aucun callback n'est demandé et le paiement n'est constaté que par la
  // vérification périodique — plus lent, mais toujours correct.
  PUBLIC_BASE_URL: vide(z.string().url()),

  NITA_BASE_URL: vide(z.string().url()),
  NITA_API_KEY: vide(z.string().min(1)),
  NITA_USERNAME: vide(z.string().min(1)),
  NITA_PASSWORD: vide(z.string().min(1)),
  // Nita ne signe pas son callback : ce secret voyage dans l'URL de rappel
  // pour écarter les appels d'inconnus. Il ne remplace pas la vérification du
  // statut auprès de Nita, il évite seulement d'aller la faire pour rien.
  NITA_WEBHOOK_SECRET: vide(z.string().min(1)),
});

const parsed = schema.safeParse(process.env);

if (!parsed.success) {
  const details = parsed.error.issues
    .map((issue) => `  ${issue.path.join('.')}: ${issue.message}`)
    .join('\n');
  throw new Error(`Environnement invalide :\n${details}`);
}

export const env = parsed.data;

/**
 * Peut-on ouvrir un achat en ligne chez Nita ?
 *
 * Le paiement mobile reste proposable même quand la réponse est non : la
 * commande part, et le livreur encaisse à l'arrivée comme pour les espèces.
 * Ce drapeau ne décide donc pas si le client peut choisir Nita, seulement si
 * le système sait lui donner un code à régler d'avance et constater ce
 * règlement tout seul.
 */
export const paiementMobileActif = Boolean(
  env.NITA_BASE_URL && env.NITA_API_KEY && env.NITA_USERNAME && env.NITA_PASSWORD,
);

/**
 * En production, livrer l'OTP dans les logs serait une faille : le code de
 * connexion de n'importe quel utilisateur deviendrait lisible par quiconque a
 * accès aux logs Railway.
 */
if (env.NODE_ENV === 'production' && env.OTP_CHANNEL === 'log') {
  throw new Error("OTP_CHANNEL=log est interdit en production : le code de connexion finirait dans les logs.");
}

/**
 * Pas de blocage au démarrage si le secret manque, malgré la tentation.
 *
 * Le hook Supabase a besoin d'une URL publique, qui n'existe qu'une fois le
 * backend déployé — refuser de démarrer sans secret rendrait le premier
 * déploiement impossible. Il n'y a pas de risque : sans secret, la route
 * /hooks/auth/send-sms refuse tout par un 503, elle n'accepte jamais un
 * appel non vérifié.
 */
if (env.NODE_ENV === 'production' && !env.AUTH_HOOK_SECRET) {
  console.warn(
    '[env] AUTH_HOOK_SECRET absent en production : la connexion par OTP restera indisponible.',
  );
}

if (env.OTP_CHANNEL === 'whatsapp' && (!env.WHATSAPP_PHONE_NUMBER_ID || !env.WHATSAPP_ACCESS_TOKEN)) {
  throw new Error('OTP_CHANNEL=whatsapp exige WHATSAPP_PHONE_NUMBER_ID et WHATSAPP_ACCESS_TOKEN.');
}

export const isProduction = env.NODE_ENV === 'production';
