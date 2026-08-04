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
  GEMINI_MODEL: z.string().default('gemini-3.5-flash-lite'),

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
