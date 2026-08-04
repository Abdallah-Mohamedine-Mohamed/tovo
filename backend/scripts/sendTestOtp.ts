/**
 * Envoi d'un vrai code de connexion, pour vérifier la chaîne WhatsApp.
 *
 * Passe par `deliverOtp` et non par une requête bricolée : c'est exactement
 * le chemin qu'empruntera le hook Supabase. Un test qui contourne le module
 * ne prouve rien sur ce qui tournera en production.
 *
 * À relancer après tout changement de modèle chez Meta : le nom, la langue et
 * la présence d'un bouton doivent s'accorder au modèle approuvé, et une
 * discordance ne se voit qu'à l'envoi.
 *
 *   npm run otp:test -- +22786967908
 */

const numero = process.argv[2];
if (!numero) {
  console.error('Usage : npm run otp:test -- +22786967908');
  process.exit(1);
}

// AVANT tout import du module : `config/env.ts` fige la configuration à son
// chargement. Poser la variable après coup ne changeait rien — le script
// passait par le canal « log » tout en annonçant un envoi réussi chez Meta.
// Un test qui ment est pire que pas de test.
process.env['OTP_CHANNEL'] = 'whatsapp';

const { deliverOtp } = await import('../src/services/whatsapp.js');
const { env } = await import('../src/config/env.js');

if (env.OTP_CHANNEL !== 'whatsapp') {
  console.error('Le canal n’est pas WhatsApp : rien ne serait réellement envoyé.');
  process.exit(1);
}

const code = String(Math.floor(100000 + Math.random() * 900000));
console.log(`modèle « ${env.WHATSAPP_TEMPLATE_NAME} » (${env.WHATSAPP_TEMPLATE_LOCALE})`);
console.log(`envoi du code ${code} vers ${numero} …`);

try {
  await deliverOtp({ phone: numero, code });
  console.log('✓ accepté par Meta — regarde ton WhatsApp');
} catch (cause) {
  const e = cause as { message?: string; status?: number; details?: unknown };
  console.error(`✗ ${e.message} (HTTP ${e.status})`);
  console.error(JSON.stringify(e.details, null, 2)?.slice(0, 700));
  process.exit(1);
}
