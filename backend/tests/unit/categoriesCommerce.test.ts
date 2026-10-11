import { afterEach, describe, expect, it } from 'vitest';
import {
  carteCommerces, categorieNommee, commercesDuType, commercesPourProduit, installerCommerces, type Commerce,
} from '../../src/services/commerces.js';

const fiche = (id: string, nom: string, type: Commerce['type'], categorie: string | undefined, lat: number): Commerce => ({
  id, nom, nom_normalise: nom.toLowerCase(), type, ...(categorie ? { categorie } : {}), adresse: null, quartier: null,
  telephone: null, telephone_appel: null, lat, lng: 2.11, fiabilite: 0.8, source: 'osm',
});
const client = { lat: 13.52, lng: 2.11 };

afterEach(() => installerCommerces(null));

describe('les catégories fines de l’annuaire (11/10)', () => {
  it('reconnaît la catégorie nommée, l’expression la plus longue d’abord', () => {
    expect(categorieNommee('un couturier près de moi')?.slug).toBe('couture');
    expect(categorieNommee('Je cherche un atelier de couture')?.slug).toBe('couture');
    expect(categorieNommee('une boutique de vêtements pas loin')?.slug).toBe('pret-a-porter');
    expect(categorieNommee('il me faut des lunettes')?.slug).toBe('optique');
    expect(categorieNommee('des pièces moto')?.slug).toBe('pieces-auto');
    expect(categorieNommee('je veux manger')).toBeUndefined();
  });

  it('« un atelier de couture » : les ateliers, pas le prêt-à-porter, le plus proche d’abord', () => {
    installerCommerces([
      fiche('a', 'Boutique Laila', 'vetements', 'pret-a-porter', 13.521),
      fiche('b', 'Couture Dames', 'vetements', 'couture', 13.53),
      fiche('c', 'Touba Couture', 'vetements', 'couture', 13.525),
    ]);
    const couture = commercesDuType('vetements', client, () => false, 5, 20_000, categorieNommee('un atelier de couture'));
    expect(couture.map((c) => c.nom)).toEqual(['Touba Couture', 'Couture Dames']);
    // Sans catégorie nommée : tout le type, comme avant.
    expect(commercesDuType('vetements', client, () => false, 5).map((c) => c.nom)).toEqual(['Boutique Laila', 'Touba Couture', 'Couture Dames']);
  });

  it('la carte dit ce qu’est le commerce : « Atelier de couture », pas « Vêtements »', () => {
    const items = carteCommerces([fiche('b', 'Couture Dames', 'vetements', 'couture', 13.53), fiche('d', 'Sans catégorie', 'vetements', undefined, 13.53)],
      'Faire les achats du client', 'oui:').data.items as Array<{ type: string; icone: string }>;
    expect(items.map((i) => i.type)).toEqual(['Atelier de couture', 'Vêtements']);
    // L'icône reste celle du type : l'application n'a rien à changer.
    expect(items[0]!.icone).toBe('vetements');
  });

  it('un produit qui nomme une catégorie (« des lunettes ») va à ses commerces', () => {
    installerCommerces([
      fiche('e', 'Grande Boutique', 'boutique', undefined, 13.521),
      fiche('f', 'Centre Lunetier', 'boutique', 'optique', 13.54),
    ]);
    expect(commercesPourProduit('des lunettes de soleil', client).map((c) => c.nom)).toEqual(['Centre Lunetier']);
  });
});
