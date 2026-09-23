/**
 * Phrases de clients, étiquetées à la main, pour comparer Jev aux détecteurs
 * à base de mots (src/ai/intents.ts).
 *
 * À ENRICHIR avec de vraies phrases tirées des conversations — surtout en
 * zarma, en haoussa et en mélange avec le français : c'est là que les listes
 * de mots cassent, et c'est ce que ce banc doit mesurer.
 */

import type { Intention } from '../../src/ai/jev.js';

export { INTENTIONS, type Intention } from '../../src/ai/jev.js';

export const PHRASES: Array<[string, Intention]> = [
  // Recherche d'un produit précis
  ['Du riz au gras', 'recherche'],
  ['avez vous du coca', 'recherche'],
  ['Je cherche des tacos poulet', 'recherche'],
  ['2 pizzas margherita', 'recherche'],
  ['pain', 'recherche'],
  ['jveu du poulet braisé stp', 'recherche'],
  ['il y a du lait en poudre ?', 'recherche'],
  ['un tacos bowl', 'recherche'],
  ['brochettes de mouton', 'recherche'],
  ['Je voudrais commander du fonio', 'recherche'],

  // Envie ou besoin général
  ['Je veux faire mes courses', 'envie'],
  ['Je cherche un bon restaurant à Niamey', 'envie'],
  ['Une idée pour ce soir ?', 'envie'],
  ['j’ai faim', 'envie'],
  ['je veux manger', 'envie'],
  ['quoi de bon aujourd’hui', 'envie'],
  ['propose moi quelque chose de pas cher', 'envie'],
  ['aide moi à préparer un repas pour 10 personnes', 'envie'],

  // Boutique nommée
  ['Otakoss', 'boutique'],
  ['montre moi la carte de chez Otakoss', 'boutique'],
  ['est-ce que le restaurant Le Pilier est ouvert', 'boutique'],
  ['qu’est-ce qu’il y a chez Boba', 'boutique'],
  ['les produits de la boutique Issa', 'boutique'],

  // Un livreur, tout court
  ['Je veux un livreur', 'livreur'],
  ['envoie moi un coursier', 'livreur'],
  ['un livreur svp', 'livreur'],
  ['j’ai besoin d’un livreur vite', 'livreur'],
  ['vous pouvez m’envoyer quelqu’un pour une course ?', 'livreur'],
  ['il me faut une moto pour une course', 'livreur'],

  // Colis
  ['Je veux envoyer un colis', 'colis'],
  ['envoie ce paquet à ma sœur à Harobanda', 'colis'],
  ['faire livrer des documents au Plateau', 'colis'],
  ['je dois déposer un colis chez Moussa, 90 12 34 56', 'colis'],
  ['tu peux transporter un sac jusqu’à Yantala ?', 'colis'],

  // Désigne ce qui est affiché
  ['le deuxième', 'designe'],
  ['ajoute-le', 'designe'],
  ['celui à 2000', 'designe'],
  ['je prends le moins cher', 'designe'],
  ['mets moi le premier', 'designe'],
  ['celui-là avec le fromage', 'designe'],
  ['je le prends', 'designe'],

  // Commande passée
  ['comme d’habitude', 'habitude'],
  ['la même chose que la dernière fois', 'habitude'],
  ['reprends ma dernière commande', 'habitude'],
  ['recommande ce que j’ai pris hier', 'habitude'],
  ['pareil que samedi', 'habitude'],

  // Suivi
  ['Où est mon livreur ?', 'suivi'],
  ['ma commande arrive quand', 'suivi'],
  ['ça fait une heure que j’attends', 'suivi'],
  ['le livreur est où', 'suivi'],
  ['c’est bientôt prêt ?', 'suivi'],

  // Annuler
  ['annule ma commande', 'annuler'],
  ['je ne veux plus rien, annulez', 'annuler'],
  ['stop, laisse tomber la commande', 'annuler'],
  ['je me suis trompé, supprime la commande', 'annuler'],

  // Social
  ['Bonjour', 'social'],
  ['merci beaucoup', 'social'],
  ['tu es nul', 'social'],
  ['ça va ?', 'social'],
  ['cc', 'social'],
  ['vous êtes les meilleurs', 'social'],
];
