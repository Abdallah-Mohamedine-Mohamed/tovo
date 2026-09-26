import { describe, expect, it } from 'vitest';
import { filtrerSuggestionsProches } from '../../src/services/catalogue.js';

const produit = (name: string, description = '') =>
  ({ id: name, name, description, price: 1000, is_available: true, merchant_id: 'm' }) as never;

describe('suggestions par faute de frappe', () => {
  it('« livre » ne mène pas à ce qui se vend au litre', () => {
    const items = [
      produit('5Alive', 'Jus de fruits, bouteille de 1 litre'),
      produit('Eau minérale 1,5l', 'Bouteille 1,5 litre'),
      produit('Huile Dinor 1L', 'Huile végétale, 1 litre'),
    ];
    expect(filtrerSuggestionsProches('livre', items)).toEqual([]);
  });

  it('une vraie faute sur un vrai mot passe toujours', () => {
    const items = [produit('Hamburger'), produit('Double Cheeseburger'), produit('Eau minérale')];
    expect(filtrerSuggestionsProches('hamburgr', items).map((i: { name: string }) => i.name)).toEqual(['Hamburger']);
    expect(filtrerSuggestionsProches('doble', items).map((i: { name: string }) => i.name)).toEqual(['Double Cheeseburger']);
  });
});
