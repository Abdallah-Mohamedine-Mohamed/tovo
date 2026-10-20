import { describe, expect, it } from 'vitest';
import { quantiteDemandee, quantites, selonQuantite } from '../../src/services/contenance.js';

describe('contenances', () => {
  it('lit les écritures usuelles', () => {
    expect(quantites('Gani Gaz (12kg)')).toEqual([{ valeur: 12000, unite: 'g' }]);
    expect(quantites('gaz 12 kg')).toEqual([{ valeur: 12000, unite: 'g' }]);
    expect(quantites('Huile Dinor 5L')).toEqual([{ valeur: 5000, unite: 'ml' }]);
    expect(quantites('gel douche 1 litre')).toEqual([{ valeur: 1000, unite: 'ml' }]);
    expect(quantites('Coca 33 cl')).toEqual([{ valeur: 330, unite: 'ml' }]);
    expect(quantites("Bouteille d'eau 1/2L")).toEqual([{ valeur: 500, unite: 'ml' }]);
    expect(quantites('Eau minérale 0,5L')).toEqual([{ valeur: 500, unite: 'ml' }]);
    expect(quantites('Lindt Noir 99% Cacao 50G')).toEqual([{ valeur: 50, unite: 'g' }]);
  });

  it("ne confond pas un nombre avec une contenance", () => {
    expect(quantites('Toner 44A')).toEqual([]);
    expect(quantites('Chargeur 67 W')).toEqual([]);
    expect(quantites('Tenda 4G LTE')).toEqual([]);
    expect(quantites('Pizza 4 fromages')).toEqual([]);
  });

  it("un lot garde la contenance de l'unité", () => {
    expect(quantites('Eau 6 x 1 L')).toEqual([{ valeur: 1000, unite: 'ml' }]);
  });

  it('compare des quantités, pas du texte', () => {
    const unKilo = quantiteDemandee('riz basmati 1 kg')!;
    expect(selonQuantite('Riz basmati 11 kg', unKilo)).toBe('autre');
    expect(selonQuantite('Riz basmati sachet de 1 kg', unKilo)).toBe('conforme');
    expect(selonQuantite('Riz basmati 1000 g', unKilo)).toBe('conforme');
    const unLitre = quantiteDemandee('gel douche citron 1 litre')!;
    expect(selonQuantite('Gel douche citron 2 L', unLitre)).toBe('autre');
    expect(selonQuantite('Shower Gel 1000 ml', unLitre)).toBe('conforme');
    expect(selonQuantite('Gel douche citron', unLitre)).toBe('inconnue');
    // Une masse ne se compare pas à un volume.
    expect(selonQuantite('Lait 400 g', unLitre)).toBe('inconnue');
  });

  it('pas de contenance demandée, ou deux : rien à exiger', () => {
    expect(quantiteDemandee('poulet frit')).toBeNull();
    expect(quantiteDemandee('gaz 6 kg ou 12 kg')).toBeNull();
  });
});
