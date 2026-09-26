import { describe, expect, it } from 'vitest';
import { marquerLePlusCommande, parPopularite } from '../../src/services/popularite.js';

const produits = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }];
const commandes = new Map([['c', 5], ['b', 2], ['d', 1]]);

describe('ce que les autres commandent', () => {
  it('les plus commandés remontent, les autres gardent leur ordre', () => {
    expect(parPopularite(produits, commandes).map((p) => p.id)).toEqual(['c', 'b', 'd', 'a']);
    expect(parPopularite(produits, new Map()).map((p) => p.id)).toEqual(['a', 'b', 'c', 'd']);
  });

  it('marque LE plus commandé, sans jamais transmettre de chiffre', () => {
    const marques = marquerLePlusCommande(produits, commandes);
    expect(marques.filter((p) => p.plus_commande).map((p) => p.id)).toEqual(['c']);
    expect(JSON.stringify(marques)).not.toMatch(/\d/);
  });

  it('une commande isolée ne fait pas un « plus commandé »', () => {
    expect(marquerLePlusCommande(produits, new Map([['d', 1]])).some((p) => p.plus_commande)).toBe(false);
  });
});
