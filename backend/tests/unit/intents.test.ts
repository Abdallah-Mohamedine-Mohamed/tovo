import { describe, expect, it } from 'vitest';
import {
  boutiquesCorrespondantes,
  boutiquesMentionnees,
  demandeBoutiqueOuverte,
  demandeDeCommandePassee,
  demandeDeProximite,
  demandeDeRepas,
  demandeGeneraleDeRepas,
  nomBoutiqueApresMarqueur,
  normaliserIntention,
  messageConversationnel,
  referenceAuxResultats,
  requeteProduitUtilisateur,
} from '../../src/ai/intents.js';

const BOUTIQUES = [
  { id: 'garba', name: "GARBA D'OR" },
  { id: 'otakoss-centre', name: "O'TAKOSS ( Centre Aéré )" },
  { id: 'otakoss-marche', name: "O'TAKOSS ( Nouveau Marché )" },
  { id: 'pharmacie', name: 'PARAPHARMACIE' },
];

describe('intentions de catalogue', () => {
  it('normalise accents, apostrophes et ponctuation', () => {
    expect(normaliserIntention("O'TAKOSS — Centre Aéré")).toBe('o takoss centre aere');
  });

  it('distingue une envie générale d’un plat précis', () => {
    expect(demandeGeneraleDeRepas('Je veux manger')).toBe(true);
    expect(demandeGeneraleDeRepas("J'ai faim")).toBe(true);
    expect(demandeGeneraleDeRepas('Je veux manger du poulet')).toBe(false);
    expect(demandeDeRepas('Je cherche un restaurant')).toBe(true);
  });

  it('ne déduit la proximité que si le client la demande', () => {
    expect(demandeDeProximite("Cherche Garba d'Or dans le coin")).toBe(true);
    expect(demandeDeProximite("Montre les plats de Garba d'Or")).toBe(false);
  });

  it('distingue une demande de boutique ouverte de son nom', () => {
    expect(demandeBoutiqueOuverte('Qu’importe, une boutique ouverte présentement')).toBe(true);
    expect(nomBoutiqueApresMarqueur('Boutique ouverte présentement')).toBeNull();
    expect(nomBoutiqueApresMarqueur('Boutique ouverte en ce moment sur Otakoss')).toBe('otakoss');
    expect(nomBoutiqueApresMarqueur('Boutique Otakoss')).toBe('otakoss');
  });

  it('retrouve une enseigne même entourée de mots', () => {
    expect(
      boutiquesCorrespondantes("Garba d'Or dans le coin", BOUTIQUES).map((b) => b.id),
    ).toEqual(['garba']);
  });

  it('tolère une faute courte sans inventer une autre enseigne', () => {
    expect(boutiquesCorrespondantes("Garda d'Or", BOUTIQUES).map((b) => b.id)).toEqual([
      'garba',
    ]);
    expect(boutiquesCorrespondantes('restaurant inconnu', BOUTIQUES)).toEqual([]);
  });

  it('conserve toutes les agences portant la même enseigne', () => {
    expect(boutiquesCorrespondantes('otakoss', BOUTIQUES).map((b) => b.id)).toEqual([
      'otakoss-centre',
      'otakoss-marche',
    ]);
  });

  it('reconnait une boutique dans le message sans dependre du modele', () => {
    expect(boutiquesMentionnees("Garba d'or", BOUTIQUES).map((b) => b.id)).toEqual([
      'garba',
    ]);
    expect(
      boutiquesMentionnees("Je veux manger chez Garda d'or", BOUTIQUES).map((b) => b.id),
    ).toEqual(['garba']);
    expect(
      boutiquesMentionnees("Montre les plats de GARBA D'OR", BOUTIQUES).map((b) => b.id),
    ).toEqual(['garba']);
  });

  it('ne confond pas un aliment et une boutique du meme nom', () => {
    const avecPoulet = [...BOUTIQUES, { id: 'poulet', name: 'POULET' }];
    expect(boutiquesMentionnees('Je veux manger du poulet', avecPoulet)).toEqual([]);
    expect(boutiquesMentionnees('Poulet', avecPoulet)).toEqual([]);
    expect(boutiquesMentionnees('chez Poulet', avecPoulet).map((b) => b.id)).toEqual([
      'poulet',
    ]);
  });

  it('ne croit le filtre boutique du modele que si le client en designe une', () => {
    expect(nomBoutiqueApresMarqueur('Je veux manger du poulet')).toBeNull();
    expect(nomBoutiqueApresMarqueur('Montre-moi les plats chez Poulet')).toBe('poulet');
    expect(nomBoutiqueApresMarqueur("J'ai envie de commander un restaurant. En fait j'ai envie de poulet.")).toBeNull();
    expect(nomBoutiqueApresMarqueur("Un restaurant, en fait un tacos de chez O'Tacos"))
      .toBe('o tacos');
  });

  it('conserve le produit demandé sans les mots de conversation', () => {
    expect(requeteProduitUtilisateur('De la pommade')).toBe('pommade');
    expect(requeteProduitUtilisateur('Un bracelet ?')).toBe('bracelet');
    expect(requeteProduitUtilisateur('Mais c’est un casque de moto ça')).toBe('casque moto');
    expect(requeteProduitUtilisateur('Avez-vous une autre montre, quelle que soit la marque ?'))
      .toBe('montre');
    expect(requeteProduitUtilisateur('Montre-moi un bracelet')).toBe('bracelet');
    expect(requeteProduitUtilisateur("J'ai envie de commander un restaurant. En fait j'ai envie de poulet. Qu'est-ce que vous avez comme poulet dans votre catalogue ?"))
      .toBe('poulet');
  });

  it('reconnait une réaction qui ne doit pas lancer le catalogue', () => {
    expect(messageConversationnel('Tu es bête')).toBe(true);
    expect(messageConversationnel('Bonjour, ça va ?')).toBe(true);
    expect(messageConversationnel('montre')).toBe(false);
  });
});

describe("référence à un résultat déjà affiché", () => {
  it("reconnaît le rang, le démonstratif et le pronom", () => {
    for (const phrase of [
      "Le deuxième",
      "je prends le 2",
      "la 3e",
      "le dernier",
      "le numéro 4",
      "celui à 2000",
      "celle-là",
      "Ajoute-le",
      "mets-les",
      "je le prends",
      "je prends ça",
      "le même",
      "pareil",
      "le moins cher",
    ]) {
      expect(referenceAuxResultats(phrase), phrase).toBe(true);
    }
  });

  it("laisse passer une vraie recherche de produit", () => {
    for (const phrase of [
      "du poulet",
      "ajoute le poulet braisé",
      "je veux une pizza",
      "avez-vous du gaz",
      "de la vaisselle",
      "Bonjour",
    ]) {
      expect(referenceAuxResultats(phrase), phrase).toBe(false);
    }
  });
});

describe("reprise d’une commande passée", () => {
  it("reconnaît le client qui revient", () => {
    for (const phrase of [
      "Comme d’habitude",
      "la même chose que la dernière fois",
      "reprends ma dernière commande",
      "je veux refaire ma commande d’hier",
      "même chose",
      "Reprendre : Tacos XL [recommander:3a1ab2f3-ba3f-4970-9731-cd5b52fc0d18]",
    ]) {
      expect(demandeDeCommandePassee(phrase), phrase).toBe(true);
    }
  });

  it("ne confond pas « recommander » au sens de conseiller, ni une recherche", () => {
    for (const phrase of ["tu me recommandes quoi ?", "recommande-moi un plat", "du poulet", "le dernier iPhone"]) {
      expect(demandeDeCommandePassee(phrase), phrase).toBe(false);
    }
  });
});
