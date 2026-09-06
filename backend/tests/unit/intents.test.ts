import { describe, expect, it } from 'vitest';
import {
  boutiquesCorrespondantes,
  demandeDeProximite,
  demandeDeRepas,
  demandeGeneraleDeRepas,
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
});
