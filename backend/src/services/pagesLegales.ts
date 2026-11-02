/**
 * Les pages publiques de confidentialité et de conditions d'utilisation
 * (02/11), demandées par Apple et Google et ouvertes depuis le profil.
 *
 * PREMIÈRE RÉDACTION, à faire relire par le fondateur (et idéalement un
 * juriste) avant la soumission aux stores. Les crochets [ ] marquent ce
 * qui reste à compléter : la raison sociale et l'adresse de l'éditeur.
 */

const EDITEUR = '[Raison sociale de l’éditeur de Tovo]';
const ADRESSE = '[Adresse de l’éditeur], Niamey, Niger';
const TELEPHONE = '+227 76 76 20 20';
const MISE_A_JOUR = '2 novembre 2026';

const CONFIDENTIALITE = `
<h1>Confidentialité</h1>
<p class="maj">Mise à jour le ${MISE_A_JOUR}</p>
<p>Tovo vous fait livrer repas, courses et colis à Niamey. Pour cela, nous avons besoin de quelques informations sur vous. Cette page dit lesquelles, pourquoi, avec qui elles sont partagées et comment les effacer.</p>

<h2>Ce que nous recueillons</h2>
<ul>
  <li><b>Votre numéro de téléphone</b> : il sert à vous connecter (code de vérification) et au livreur pour vous joindre.</li>
  <li><b>Votre nom</b>, tel que vous l’avez saisi.</li>
  <li><b>Vos adresses et votre position</b>, quand vous les donnez : pour livrer au bon endroit et vous montrer ce qui est proche.</li>
  <li><b>Vos commandes</b> : articles, montants, boutiques, heures.</li>
  <li><b>Vos échanges avec Tovo</b> : messages écrits, notes vocales et photos que vous envoyez. Une note vocale est transcrite en texte, puis le son est supprimé.</li>
  <li><b>Des informations techniques</b> : type de téléphone, version de l’application, erreurs, pour corriger les problèmes.</li>
</ul>

<h2>Pourquoi</h2>
<ul>
  <li>Prendre, préparer et livrer vos commandes.</li>
  <li>Comprendre vos demandes et vous répondre.</li>
  <li>Vous prévenir de l’avancement de votre commande.</li>
  <li>Améliorer Tovo, et lutter contre la fraude.</li>
</ul>
<p>Nous ne vendons pas vos données.</p>

<h2>Avec qui elles sont partagées</h2>
<ul>
  <li><b>La boutique</b> qui prépare votre commande voit votre nom et ce que vous avez commandé.</li>
  <li><b>Le livreur</b> voit votre nom, votre numéro et l’adresse de livraison, le temps de la course.</li>
  <li><b>Nos prestataires techniques</b>, seulement pour faire fonctionner le service : hébergement des données (Supabase), serveurs (Railway), cartes et adresses (Google Maps), compréhension des messages et des notes vocales (Google Gemini, OpenAI, Microsoft), notifications (Firebase), suivi des erreurs (Sentry). Certains sont situés hors du Niger.</li>
  <li><b>Les autorités</b>, si la loi nous y oblige.</li>
</ul>

<h2>Combien de temps</h2>
<p>Vos informations sont gardées tant que votre compte existe. Si vous le supprimez, elles sont effacées, sauf les commandes passées : elles restent pour la comptabilité des boutiques et des livreurs, sans votre nom, sans votre numéro et sans votre adresse.</p>

<h2>Vos droits</h2>
<p>Vous pouvez consulter et corriger votre nom dans <b>Mon profil</b>, et <b>supprimer votre compte</b> depuis l’application : Menu, Mon profil, Supprimer mon compte. Pour toute autre demande (accès, rectification, opposition), écrivez-nous ou appelez le ${TELEPHONE}. Vous pouvez aussi saisir l’autorité nigérienne chargée de la protection des données personnelles.</p>

<h2>Nous contacter</h2>
<p>${EDITEUR}, ${ADRESSE}. Téléphone et WhatsApp : ${TELEPHONE}.</p>
`;

const CONDITIONS = `
<h1>Conditions d’utilisation</h1>
<p class="maj">Mise à jour le ${MISE_A_JOUR}</p>
<p>Tovo est édité par ${EDITEUR}, ${ADRESSE}. En utilisant l’application, vous acceptez ces conditions.</p>

<h2>Le service</h2>
<p>Tovo met en relation des clients, des boutiques partenaires et des livreurs à Niamey. Vous pouvez commander des articles proposés par les boutiques, ou demander à un livreur une course (colis, achat). Tovo vous aide aussi à trouver des commerces qui ne sont pas sur l’application : ces informations viennent de sources publiques et peuvent être inexactes.</p>

<h2>Votre compte</h2>
<p>Votre compte est lié à votre numéro de téléphone. Vous êtes responsable de ce qui est fait depuis votre téléphone. Vous pouvez supprimer votre compte à tout moment depuis l’application.</p>

<h2>Commandes, prix et paiement</h2>
<ul>
  <li>Les prix sont fixés par les boutiques. Le total, frais de livraison compris, est affiché avant que vous confirmiez.</li>
  <li>Le paiement se fait à la livraison, en espèces, sauf autre moyen proposé dans l’application.</li>
</ul>

<h2>Courses et achats par un livreur</h2>
<p>Quand un livreur achète pour vous dans un commerce qui n’est pas sur Tovo, il vous appelle pour confirmer ce que vous voulez. Vous remboursez l’achat à la livraison, avec le prix de la course.</p>

<h2>L’assistant</h2>
<p>Tovo répond à vos messages avec l’aide d’une intelligence artificielle. Seules les informations affichées sur les cartes de commande (articles, prix, délais) engagent Tovo ; vérifiez-les avant de confirmer.</p>

<h2>Ce qui est interdit</h2>
<p>Commander des produits illégaux, utiliser Tovo pour nuire, tromper les boutiques ou les livreurs, ou perturber le service. Tovo peut suspendre un compte en cas d’abus.</p>

<h2>Responsabilité</h2>
<p>Les boutiques sont responsables des produits qu’elles vendent. Tovo fait de son mieux pour que le service fonctionne et que les livraisons arrivent à l’heure, sans pouvoir le garantir en toutes circonstances.</p>

<h2>Nous contacter</h2>
<p>Téléphone et WhatsApp : ${TELEPHONE}. Ces conditions sont régies par le droit nigérien.</p>
`;

const STYLE = `
:root{color-scheme:light dark;--fond:#FFFFFF;--texte:#14201E;--doux:#55615D}
@media (prefers-color-scheme:dark){:root{--fond:#111614;--texte:#EEF1EF;--doux:#A3ADA9}}
body{margin:0;background:var(--fond);color:var(--texte);font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:680px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:28px;line-height:1.2;margin:0 0 4px}
h2{font-size:19px;margin:32px 0 8px}
.maj{color:var(--doux);font-size:14px;margin:0 0 24px}
ul{padding-left:20px}li{margin:6px 0}`;

export function pageLegale(page: 'confidentialite' | 'conditions'): string {
  const titre = page === 'confidentialite' ? 'Confidentialité' : 'Conditions d’utilisation';
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tovo — ${titre}</title><style>${STYLE}</style></head><body><main>${page === 'confidentialite' ? CONFIDENTIALITE : CONDITIONS}</main></body></html>`;
}
