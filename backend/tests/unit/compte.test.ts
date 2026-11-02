import { describe, expect, it } from 'vitest';
import { FENETRE_RECONFIRMATION_MS, reconfirmeRecemment } from '../../src/routes/compte.js';
import { pageLegale } from '../../src/services/pagesLegales.js';

describe('suppression du compte', () => {
  const maintenant = Date.parse('2026-11-02T12:00:00Z');
  it('exige une connexion toute fraîche', () => {
    expect(reconfirmeRecemment('2026-11-02T11:58:00Z', maintenant)).toBe(true);
    expect(reconfirmeRecemment(new Date(maintenant - FENETRE_RECONFIRMATION_MS - 1000).toISOString(), maintenant)).toBe(false);
    expect(reconfirmeRecemment(null, maintenant)).toBe(false);
    expect(reconfirmeRecemment('pas une date', maintenant)).toBe(false);
  });
});

describe('pages légales', () => {
  it('disent comment supprimer son compte et qui appeler', () => {
    const page = pageLegale('confidentialite');
    expect(page).toContain('Supprimer mon compte');
    expect(page).toContain('+227 76 76 20 20');
    expect(pageLegale('conditions')).toContain('Conditions d’utilisation');
  });
});
