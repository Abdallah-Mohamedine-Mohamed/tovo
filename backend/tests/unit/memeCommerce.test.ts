import { describe, expect, it } from 'vitest';
import { memeCommerce } from '../../src/services/commerces.js';

describe('memeCommerce : un commerce de l’annuaire est-il déjà sur Tovo ? (05/10)', () => {
  it('reconnaît le même commerce malgré une faute, un quartier ou un mot générique', () => {
    expect(memeCommerce('Baklini', "BAAKLINI ( Centre Aéré )")).toBe(true);
    expect(memeCommerce('Baaklini chateau 1', "BAAKLINI ( Centre Aéré )")).toBe(true);
    expect(memeCommerce('Royal Grill', 'ROYAL GRILL STEAK HOUSE')).toBe(true);
    expect(memeCommerce('Restaurant KARASSOU', 'RESTAURANT KARASU')).toBe(true);
  });
  it('ne confond pas deux commerces qui partagent un mot', () => {
    expect(memeCommerce('FRENCH TACOS', "O'TAKOSS ( Centre Aéré )")).toBe(false);
    expect(memeCommerce('FRENCH TACOS', 'O TACOS')).toBe(false);
    expect(memeCommerce('Nouhou Merguez', 'NOUHOU MARKET')).toBe(false);
    expect(memeCommerce('Pharmacie du Ténéré', 'TENERE SHOP')).toBe(false);
    expect(memeCommerce('Nass Telecom 227', '227 TWO TWO SEVEN ( plateau )')).toBe(false);
    expect(memeCommerce('Le Café Restaurant', 'RESTAURANT AFC')).toBe(false);
  });
});
