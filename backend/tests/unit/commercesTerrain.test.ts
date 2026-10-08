import { afterAll, describe, expect, it } from 'vitest';
import { chargerCommerces, commercesPourProduit, installerCommerces, installerTerrain, type Commerce } from '../../src/services/commerces.js';
import { normaliserIntention } from '../../src/ai/intents.js';

const commerce = (id: string, nom: string, source: Commerce['source'], lat: number): Commerce => ({
  id, nom, nom_normalise: normaliserIntention(nom), type: 'vetements', adresse: null, quartier: 'Yantala',
  telephone: null, telephone_appel: null, lat, lng: 2.1, fiabilite: source === 'terrain' ? 1 : 0.6, source,
});

describe('les commerces relevés sur le terrain rejoignent l’annuaire (07/10)', () => {
  afterAll(() => installerCommerces(null));

  it('validés, ils s’ajoutent à l’annuaire et sont trouvés comme les autres', () => {
    installerCommerces([commerce('osm:1', 'Boutique Ancienne', 'osm', 13.53)]);
    expect(chargerCommerces().map((c) => c.nom)).toEqual(['Boutique Ancienne']);
    installerTerrain([commerce('terrain:1', 'Friperie Mariama', 'terrain', 13.501)]);
    expect(chargerCommerces().map((c) => c.nom)).toEqual(['Boutique Ancienne', 'Friperie Mariama']);
    // Le plus proche d'abord : la fiche du terrain, à 110 m.
    expect(commercesPourProduit('des pagnes', { lat: 13.5, lng: 2.1 })[0]?.nom).toBe('Friperie Mariama');
  });

  it('une nouvelle lecture remplace les fiches précédentes (une fiche retirée disparaît)', () => {
    installerCommerces([commerce('osm:1', 'Boutique Ancienne', 'osm', 13.53)]);
    installerTerrain([commerce('terrain:1', 'Friperie Mariama', 'terrain', 13.501)]);
    installerTerrain([]);
    expect(chargerCommerces().map((c) => c.nom)).toEqual(['Boutique Ancienne']);
  });
});

describe('les catégories des livreurs (08/10)', () => {
  afterAll(() => installerCommerces(null));

  it('« Pièces auto » → « pieces-auto » : la clé d’une catégorie', async () => {
    const { cleDeCategorie } = await import('../../src/services/commercesTerrain.js');
    expect(cleDeCategorie('Pièces auto')).toBe('pieces-auto');
    expect(cleDeCategorie('  Friperie ')).toBe('friperie');
  });

  it('un client qui demande la catégorie trouve le commerce, même en plusieurs mots', () => {
    installerCommerces([]);
    installerTerrain([
      { ...commerce('terrain:2', 'Garage Issa', 'terrain', 13.52), type: 'boutique', specialites: ['Pièces auto'] },
      { ...commerce('terrain:3', 'Chez Fati', 'terrain', 13.51), type: 'vetements', specialites: ['Friperie'] },
    ]);
    expect(commercesPourProduit('je cherche des pièces auto', { lat: 13.5, lng: 2.1 }).map((c) => c.nom)).toContain('Garage Issa');
    expect(commercesPourProduit('une friperie pas loin', { lat: 13.5, lng: 2.1 })[0]?.nom).toBe('Chez Fati');
    expect(commercesPourProduit('des friperies', { lat: 13.5, lng: 2.1 })[0]?.nom).toBe('Chez Fati');
  });
});
