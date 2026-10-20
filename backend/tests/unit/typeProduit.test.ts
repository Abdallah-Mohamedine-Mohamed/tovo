import { describe, expect, it } from 'vitest';
import { classerParType, nettoyerTypes } from '../../src/services/typeProduit.js';

const biscuit = { id: 'b', name: 'Biscuits Cuillers Chocolat Noir' };
const lindt = { id: 'l', name: 'Lindt Excellence Noir 99 %' };
const savon = { id: 's', name: 'Baléa Crème Seife' };
const lait = { id: 'v', name: 'Lait Corps & Mains' };
const TYPES = new Map([
  ['b', ['biscuit à la cuillère', 'biscuit']],
  ['l', ['tablette de chocolat', 'chocolat']],
  ['s', ['savon liquide', 'savon']],
  ['v', ['lait corporel', 'crème']],
]);

describe('classement par type', () => {
  it('ce que le client nomme passe devant ce qui en contient le mot', () => {
    expect(classerParType('chocolat noir', [biscuit, lindt], TYPES)).toEqual([lindt, biscuit]);
    expect(classerParType('crème pour les mains', [savon, lait], TYPES)).toEqual([lait, savon]);
  });

  it("dans l'ordre où la phrase les nomme", () => {
    expect(classerParType('biscuits au chocolat', [lindt, biscuit], TYPES)).toEqual([biscuit, lindt]);
  });

  it('ne retire rien, ne bouge rien quand aucun type n’est nommé', () => {
    expect(classerParType('noir', [biscuit, lindt], TYPES)).toEqual([biscuit, lindt]);
    expect(classerParType('chocolat noir', [biscuit, lindt], new Map())).toEqual([biscuit, lindt]);
    expect(classerParType('chocolat', [lindt], TYPES)).toEqual([lindt]);
  });

  it('pluriel et accents', () => {
    expect(classerParType('crèmes', [savon, lait], TYPES)).toEqual([lait, savon]);
  });

  it('types nettoyés', () => {
    expect(nettoyerTypes([' Savon ', 'savon', 'x', 'Savon liquide', 'a', 'b4', 'c5'])).toEqual(['savon', 'savon liquide', 'b4']);
  });
});
