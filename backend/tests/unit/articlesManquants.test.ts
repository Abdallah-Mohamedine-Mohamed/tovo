import { describe, expect, it } from 'vitest';
import { choisirSuggestions, type ProduitCandidat } from '../../src/services/articlesManquants.js';

const p = (id: string, price: number, extra: Partial<ProduitCandidat> = {}): ProduitCandidat =>
  ({ id, name: id, price, image_url: null, category_id: 'pizzas', is_available: true, ...extra });

describe('remplacements proposés pour un article manquant', () => {
  const manquant = { product_id: 'double-fromage', prix: 4250, category_id: 'pizzas' };

  it('même rayon, prix proche, en vente, pas déjà commandé ; deux au plus', () => {
    const candidats = [
      p('double-fromage', 4250),
      p('margherita', 4250),
      p('honolulu', 4250),
      p('charcuterie', 8750),
      p('classique', 4000),
      p('coca', 500, { category_id: 'boissons' }),
      p('poulet-bbq', 4300, { is_available: false }),
    ];
    const s = choisirSuggestions(manquant, candidats, new Set(['honolulu']));
    expect(s.map((x) => x.product_id)).toEqual(['margherita', 'classique']);
  });

  it('à prix égal, le plus commandé d’abord', () => {
    const s = choisirSuggestions(manquant, [p('a', 4250), p('b', 4250), p('c', 4250)], new Set(), new Map([['c', 9], ['b', 3]]));
    expect(s.map((x) => x.product_id)).toEqual(['c', 'b']);
  });

  it('rien à proposer : sans rayon connu, ou rien au bon prix', () => {
    expect(choisirSuggestions({ ...manquant, category_id: null }, [p('margherita', 4250)], new Set())).toEqual([]);
    expect(choisirSuggestions(manquant, [p('charcuterie', 8750)], new Set())).toEqual([]);
  });
});
