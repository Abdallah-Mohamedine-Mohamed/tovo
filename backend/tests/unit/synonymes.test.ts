import { describe, expect, it } from 'vitest';
import { appliquerSynonymes } from '../../src/services/synonymes.js';

const DICO = [
  { expression: 'tente ceremonie', remplacement: 'chapiteau' },
  { expression: 'tente', remplacement: 'bache' },
  { expression: 'bonbonne', remplacement: 'bouteille' },
  { expression: 'location', remplacement: '' },
];

describe('dictionnaire des synonymes', () => {
  it('remplace une expression par son synonyme', () => {
    expect(appliquerSynonymes('bonbonne gaz 12 kg', DICO)).toBe('bouteille gaz 12 kg');
  });

  it("l'expression la plus longue passe d'abord", () => {
    expect(appliquerSynonymes('tente ceremonie', DICO)).toBe('chapiteau');
    expect(appliquerSynonymes('tente camping', DICO)).toBe('bache camping');
  });

  it('ne remplace que des mots entiers', () => {
    expect(appliquerSynonymes('bonbonnes gaz', DICO)).toBeNull();
    expect(appliquerSynonymes('detente', DICO)).toBeNull();
  });

  it('ne retire jamais un mot (remplacement vide ignoré)', () => {
    expect(appliquerSynonymes('location voiture', DICO)).toBeNull();
  });

  it('rien à réécrire : null', () => {
    expect(appliquerSynonymes('poulet frit', DICO)).toBeNull();
    expect(appliquerSynonymes('poulet frit', [])).toBeNull();
  });

  it('sans doublon après remplacement', () => {
    expect(appliquerSynonymes('bonbonne bouteille', DICO)).toBe('bouteille');
  });
});
