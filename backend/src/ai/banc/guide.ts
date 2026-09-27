import { INTENTIONS, type Intention } from '../jev.js';

/**
 * Le GUIDE D'ÉTIQUETAGE : la règle écrite de ce que chaque phrase veut dire.
 *
 * Distinct de la consigne du cerveau (decideur.ts) : le juge ne doit pas
 * répéter les biais de celui qu'il corrige. Ce guide est aussi celui qu'on
 * a suivi à la main pour étiqueter jeu.ts.
 */

export const GUIDE_ETIQUETAGE = [
  'Tu étiquettes des messages de clients de Tovo, une application de livraison à Niamey (Niger) :',
  'repas des restaurants, courses (supermarchés, marché, pharmacie, beauté, électronique…), et colis ou',
  'courses de livreur. Le client écrit dans le chat de l’app, ou parle (sa voix est transcrite, parfois mal).',
  'Paiement : espèces ou Nita (paiement mobile). Les livreurs sont à moto.',
  '',
  'Les intentions (une seule par message) :',
  ...Object.entries(INTENTIONS).map(([cle, def]) => `- ${cle} : ${def}`),
  '',
  'Règles de décision, à appliquer strictement :',
  '1. recherche : le client nomme un produit ou un plat, même mal écrit ou mal transcrit, même avec « livre-moi », « apporte-moi », « envoie … chez ma mère » (c’est un achat livré, pas un colis). Un objet qui ressemble à un mot de livraison reste un produit : un livre, un litre, un paquet de biscuits, un sac ou un « colis » de riz.',
  '2. envie : une envie ou un besoin général sans produit précis (« j’ai faim », « je veux faire mes courses », « quels restaurants sont ouverts ? », « montre-moi tout »).',
  '3. boutique : le client nomme une enseigne précise et veut la voir, voir sa carte, savoir si elle est ouverte, ou y commander sans nommer de produit. « Tacos chez Otakoss » est une recherche (un produit est nommé).',
  '4. livreur : le client veut qu’un livreur SE DÉPLACE pour lui, sans commande de boutique (« envoie-moi un coursier », « j’ai une course », « il me faut une moto »). Tovo ne transporte pas de personnes : un taxi ou un Uber pour le client lui-même, c’est social.',
  '5. colis : le client veut envoyer, faire déposer ou aller chercher un objet À LUI (document, sac, téléphone) chez quelqu’un. Livreur et colis sont proches ; en cas de doute entre les deux, choisis colis si un objet ou un destinataire est mentionné, sinon livreur.',
  '6. designe : le client désigne un article qu’il voit à l’écran ou dans son panier (« le deuxième », « le moins cher », « enlève le jus », « annule le coca »).',
  '7. panier : voir, vérifier ou valider son panier (« où est mon panier ? », « je veux payer », « valide ma commande »).',
  '8. habitude : refaire une commande passée (« comme d’habitude », « la même chose que la dernière fois »).',
  '9. suivi : où en est sa commande en cours, quand elle arrive, où est le livreur (« il arrive quand ? », « c’est encore loin ? », « le livreur est où ? »).',
  '10. aide : un PROBLÈME ou une réclamation : mauvaise commande, article manquant ou abîmé, paiement Nita bloqué ou erroné, monnaie, livreur injoignable ou désagréable, vouloir modifier une commande déjà passée (« ajoutez un coca à ma commande »).',
  '11. annuler : annuler TOUTE la commande en cours. Retirer un seul article, c’est designe.',
  '12. question : SEULEMENT le service Tovo lui-même : frais de livraison, zones desservies, horaires de livraison, moyens de paiement, fonctionnement, devenir livreur ou boutique partenaire (« je veux devenir livreur », « vous recrutez ? »). Une question sur ce que Tovo propose (boutiques ouvertes, produits, catégories, prix d’un produit) n’est PAS une question : c’est envie, recherche ou boutique.',
  '13. social : salutation, remerciement, humeur, bavardage, sujet sans rapport avec Tovo (une personne, la politique, la météo), ou une remarque à l’assistant sur lui-même ou sur ce qu’il vient de dire (« d’où tu tiens ça ? », « tu connais ? »).',
  '14. Un message court qui répond au dernier message de Tovo (fourni quand il existe) s’interprète avec lui.',
  '15. Haoussa, zarma, français parlé, argot, fautes, transcription vocale approximative : juge le SENS.',
  '',
  'Si le message est réellement ambigu (deux lectures aussi plausibles l’une que l’autre, même avec le',
  'contexte), réponds "ambigu" : il ne servira pas d’examen.',
].join('\n');

export type Etiquette = Intention | 'ambigu';

export function lireEtiquette(v: unknown): Etiquette | null {
  if (v === 'ambigu') return 'ambigu';
  return typeof v === 'string' && v in INTENTIONS ? (v as Intention) : null;
}
