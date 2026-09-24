/**
 * Scénarios de bout en bout : de vraies conversations, rejouées contre le
 * vrai serveur, le vrai Gemini et la base de TEST (catalogue de semer.ts).
 *
 * Chaque bug rencontré devient un scénario ici, pour ne jamais revenir.
 * Écrire le RÉSULTAT attendu, pas la formulation exacte : Gemini ne dit
 * jamais deux fois la même phrase.
 */

export interface Attendu {
  statut?: number;
  /** Types de composants qui DOIVENT apparaître. */
  composants?: string[];
  /** Types de composants qui ne doivent PAS apparaître. */
  sansComposants?: string[];
  texte?: RegExp;
  sansTexte?: RegExp;
}

export interface Contexte {
  /** Dernière commande vue dans un suivi (order_tracking). */
  commande?: string;
}

export type Etape =
  | { dire: string; position?: boolean; attendu: Attendu }
  | { requete: (ctx: Contexte) => { methode: 'GET' | 'POST' | 'DELETE'; chemin: string; corps?: unknown }; attendu: Attendu };

export interface Scenario {
  nom: string;
  /** Pourquoi il existe : le bug ou l'exigence qu'il protège. */
  protege: string;
  etapes: Etape[];
}

const INTROUVABLE = /je ne trouve pas/i;
const DANS_LE_PANIER = /dans (votre|ton) panier|ajouté/i;

export const SCENARIOS: Scenario[] = [
  {
    nom: 'Tacos bowl : les options avant le panier',
    protege: 'Un tacos bowl est parti au panier sans que ses options soient demandées.',
    etapes: [
      // Boutique nommée : la base de dev contient d'autres tacos bowls, et
      // « ajoute-le » serait ambigu (l'IA demande alors « lequel ? », à raison).
      { dire: 'un tacos bowl chez Scénario Tacos', attendu: { composants: ['product_carousel'] } },
      {
        dire: 'ajoute-le',
        attendu: { composants: ['option_selector'], sansComposants: ['cart_summary'], sansTexte: DANS_LE_PANIER },
      },
    ],
  },
  {
    nom: 'Tacos bowl en une phrase',
    protege: 'Même demandé d’un coup, un produit à options ne s’ajoute pas sans choix.',
    etapes: [
      {
        dire: 'Ajoute un tacos bowl de chez Scénario Tacos à mon panier',
        attendu: { sansComposants: ['cart_summary'], sansTexte: DANS_LE_PANIER },
      },
    ],
  },
  {
    nom: 'Produit simple : ajout direct',
    protege: 'Le filet des options ne doit pas bloquer un produit sans option.',
    etapes: [
      { dire: 'un coca chez Scénario Tacos', attendu: { composants: ['product_carousel'] } },
      { dire: 'ajoute-le', attendu: { composants: ['cart_summary'] } },
    ],
  },
  {
    nom: 'Suggestion d’accueil : faire ses courses',
    protege: '« Je ne trouve pas de faire mes courses ».',
    etapes: [{ dire: 'Je veux faire mes courses', attendu: { sansTexte: INTROUVABLE } }],
  },
  {
    nom: 'Suggestion d’accueil : un bon restaurant',
    protege: '« Je ne trouve pas l’enseigne à Niamey ».',
    etapes: [{ dire: 'Je cherche un bon restaurant à Niamey', attendu: { sansTexte: /enseigne|je ne trouve pas/i } }],
  },
  {
    nom: 'Un livreur, sans formulaire, puis annulation',
    protege: 'Zéro étape pour un livreur ; pas de doublon ; annulable tant que personne n’est parti.',
    etapes: [
      { dire: 'Je veux un livreur', position: true, attendu: { composants: ['order_tracking'], texte: /7 minutes/ } },
      { dire: 'je veux un livreur', position: true, attendu: { texte: /déjà en route/i } },
      {
        requete: (ctx) => ({ methode: 'POST', chemin: `/orders/${ctx.commande}/cancel`, corps: {} }),
        attendu: { statut: 200, texte: /annulé/i },
      },
    ],
  },
  {
    nom: 'Envoyer un colis : une carte, aucune question',
    protege: 'On demandait taille, destination et numéro avant tout.',
    etapes: [
      {
        dire: 'Je veux envoyer un colis',
        position: true,
        attendu: { composants: ['courier_form'], sansTexte: /taille|point de départ|numéro du destinataire/i },
      },
    ],
  },
  {
    nom: 'Colis avec destinataire dit d’un coup',
    protege: 'Ce que le client a dit est repris, rien n’est redemandé.',
    etapes: [
      {
        dire: 'Envoie un paquet à Moussa au 90 12 34 56 à Harobanda',
        position: true,
        attendu: { composants: ['courier_form'], sansTexte: /quel(le)? (est|numéro)|pouvez-vous (me )?(donner|préciser)/i },
      },
    ],
  },
  {
    nom: 'Comme d’habitude, sans historique',
    protege: '« Je ne trouve pas de d habitude ».',
    etapes: [{ dire: 'comme d’habitude', attendu: { sansTexte: INTROUVABLE } }],
  },
  {
    nom: 'Bavardage : pas de recherche',
    protege: 'Une salutation ne devient jamais une recherche de produit.',
    etapes: [
      { dire: 'Bonjour', attendu: { sansComposants: ['product_carousel'], sansTexte: INTROUVABLE } },
      { dire: 'cc', attendu: { sansComposants: ['product_carousel'], sansTexte: INTROUVABLE } },
    ],
  },
  // --- Aiguillage Jev (JEV_AIGUILLAGE=1 dans .env.staging) ---------------
  {
    nom: 'Jev : une moto pour une course',
    protege: 'Les mots en faisaient une recherche de produit « moto course ».',
    etapes: [{ dire: 'il me faut une moto pour une course', position: true, attendu: { sansComposants: ['product_carousel'], sansTexte: INTROUVABLE } }],
  },
  {
    nom: 'Jev : l’impatience n’est pas une recherche',
    protege: '« ça fait une heure que j’attends » devenait la recherche de « heure attends ».',
    etapes: [{ dire: 'ça fait une heure que j’attends', attendu: { sansComposants: ['product_carousel'], sansTexte: INTROUVABLE } }],
  },
  {
    nom: 'Jev : annuler, dit autrement',
    protege: '« je ne veux plus rien, annulez » devenait une recherche.',
    etapes: [{ dire: 'je ne veux plus rien, annulez', attendu: { sansComposants: ['product_carousel'], sansTexte: INTROUVABLE } }],
  },
  {
    nom: 'Recherche d’épicerie',
    protege: 'Le cas le plus courant doit rester instantané et juste.',
    etapes: [{ dire: 'du riz', attendu: { composants: ['product_carousel'], sansTexte: INTROUVABLE } }],
  },
  // --- Captures du 24/09 (Documents/problem) -------------------------------
  {
    nom: 'Boutiques ouvertes, sans position',
    protege: '« Quelles sont les boutiques ouvertes présentement ? » répondait par les catégories.',
    etapes: [{
      dire: 'Quelles sont les boutiques ouvertes présentement ?',
      attendu: { composants: ['merchant_card'], sansComposants: ['category_grid'] },
    }],
  },
  {
    nom: 'Nom de boutique collé par la voix',
    protege: '« Garbador » donnait des « suggestions proches » au lieu de Garba d’Or.',
    etapes: [{
      dire: 'Je veux manger à Garbador. Qu’est-ce que Garbador a comme produit ?',
      attendu: { sansTexte: /suggestions proches/i },
    }],
  },
  {
    nom: 'Phrase inintelligible : pas de faux « 1278 produits »',
    protege: 'Une transcription ratée annonçait des centaines de produits sans rapport.',
    etapes: [{
      dire: 'bon l ukounou me euh reserves me bon coin bon l ukounou',
      attendu: { sansTexte: /d{3,} produits/ },
    }],
  },
  {
    nom: 'Demande de produit mal transcrite : pas de tuiles hors sujet',
    protege: '« Je veux du bon à checker » proposait « Suivre ma commande ».',
    etapes: [{
      dire: 'Je veux du bon à checker.',
      attendu: { sansTexte: /Vous voulez/ },
    }],
  },
  {
    nom: 'Livreur : plus de « Touchez Ma position »',
    protege: 'Le message restait affiché alors que la carte prend la position seule.',
    etapes: [{ dire: 'Je veux envoyer un livreur.', attendu: { composants: ['courier_form'], sansTexte: /Ma position/ } }],
  },
];
