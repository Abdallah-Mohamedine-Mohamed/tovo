import { describe, expect, it } from 'vitest';
import {
  boutiquesCorrespondantes,
  boutiquesMentionnees,
  demandeDeProximite,
  demandeDeRepas,
  demandeGeneraleDeRepas,
  nomBoutiqueApresMarqueur,
  normaliserIntention,
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
  });
});
