import { describe, expect, it } from 'vitest';
import { affichageDe, pastilles, rayonsAffiches } from '../../src/services/rayonsBoutique.js';

describe('rayons propres à une boutique', () => {
  it('garde la carte sauf si la base dit « categories »', () => {
    expect(affichageDe('categories')).toBe('categories');
    expect(affichageDe('carte')).toBe('carte');
    expect(affichageDe(undefined)).toBe('carte');
    expect(affichageDe('autre chose')).toBe('carte');
  });

  it('range les catégories dans leur ordre et cache les vides', () => {
    const rayons = [
      { cle: 'savons', nom: 'Savons', icone_url: null, ordre: 6, sous_rayons: [] },
      { cle: 'parfums', nom: 'Parfums', icone_url: 'p.png', ordre: 1, sous_rayons: [] },
      { cle: 'maquillage', nom: 'Maquillage', icone_url: null, ordre: 9, sous_rayons: [] },
    ];
    const produits = [{ rayon_boutique: 'savons' }, { rayon_boutique: 'parfums' }, { rayon_boutique: 'parfums' }, { rayon_boutique: null }];
    expect(rayonsAffiches(rayons, produits)).toEqual([
      { cle: 'parfums', nom: 'Parfums', icone_url: 'p.png', produits: 2 },
      { cle: 'savons', nom: 'Savons', icone_url: null, produits: 1 },
    ]);
  });

  it('met les pastilles voulues d’abord, puis les autres par nombre de produits', () => {
    const p = (s: string | null) => ({ sous_rayon: s });
    const produits = [p('Mixtes'), p('Coffrets'), p('Pour homme'), p('Mixtes'), p('Parfums de poche'), p('Parfums de poche'), p('Parfums de poche'), p(null)];
    expect(pastilles(['Pour homme', 'Pour femme', 'Mixtes'], produits))
      .toEqual(['Pour homme', 'Mixtes', 'Parfums de poche', 'Coffrets']);
  });

  it('ne renvoie aucune pastille quand il n’y en aurait qu’une', () => {
    expect(pastilles([], [{ sous_rayon: 'Savons' }, { sous_rayon: 'Savons' }])).toEqual([]);
  });
});
