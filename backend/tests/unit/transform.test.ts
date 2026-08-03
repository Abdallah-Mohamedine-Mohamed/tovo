import { describe, expect, it } from 'vitest';
import {
  delaiPreparation,
  nomComplet,
  normaliserTelephone,
  polygoneEstPlausible,
  polygoneVersWkt,
  slug,
  stockUtile,
  transformerOptions,
  transformerVariantes,
  versXof,
} from '../../scripts/etl/transform.js';

/**
 * Les transformations de migration.
 *
 * Une erreur ici ne fait rien planter : elle produit des données fausses,
 * insérées sans bruit. Une zone au mauvais endroit, un supplément à zéro,
 * un numéro invalide — et le boutiquier ou le client le découvre des
 * semaines plus tard.
 */

describe('polygones de zones', () => {
  // Un vrai polygone du dump 6ammart : WKB précédé de 4 octets de SRID.
  const ZONE_REELLE =
    '0x000000000103000000010000000b000000efb25bccbfe4054083a4feee2f772840' +
    'efb25bccbfa00d40c4c8539cfe422740efb25bccbfae0e40e422f7df05112940';

  it('lit le format MySQL, en sautant les 4 octets de SRID', () => {
    // Tronqué volontairement : on vérifie qu'un polygone incomplet est
    // rejeté plutôt que lu de travers.
    expect(polygoneVersWkt(ZONE_REELLE)).toBeNull();
  });

  it('rejette une entrée trop courte', () => {
    expect(polygoneVersWkt('0x0000')).toBeNull();
    expect(polygoneVersWkt('')).toBeNull();
  });

  it('détecte des coordonnées hors du Niger', () => {
    // Coordonnées inversées : latitude et longitude permutées placeraient
    // les zones de Niamey au large de la Somalie.
    expect(polygoneEstPlausible('POLYGON((2.1 13.5, 2.2 13.6, 2.1 13.5))')).toBe(true);
    expect(polygoneEstPlausible('POLYGON((13.5 2.1, 13.6 2.2, 13.5 2.1))')).toBe(false);
  });
});

describe('numéros de téléphone', () => {
  it('accepte un numéro déjà international', () => {
    expect(normaliserTelephone('+22790123456')).toBe('+22790123456');
  });

  it('ajoute l’indicatif nigérien à 8 chiffres', () => {
    expect(normaliserTelephone('90123456')).toBe('+22790123456');
  });

  it('nettoie les séparateurs', () => {
    expect(normaliserTelephone('+227 90 12 34 56')).toBe('+22790123456');
  });

  it('rejette ce qui ne peut pas être un numéro', () => {
    // Un numéro invalide créerait un compte auquel personne ne pourrait
    // jamais se connecter : mieux vaut l'écarter et le signaler.
    expect(normaliserTelephone('123')).toBeNull();
    expect(normaliserTelephone(null)).toBeNull();
    expect(normaliserTelephone('null')).toBeNull();
  });
});

describe('options de produits', () => {
  const VIANDES = JSON.stringify([
    {
      name: 'VIANDES',
      type: 'single',
      min: 0,
      max: 0,
      required: 'on',
      values: [
        { label: 'Viande Hachée', optionPrice: '0' },
        { label: 'Poulet', optionPrice: '600' },
      ],
    },
  ]);

  it('convertit une variation en option', () => {
    const [option] = transformerOptions(VIANDES);
    expect(option?.nom).toBe('VIANDES');
    expect(option?.valeurs).toHaveLength(2);
    expect(option?.valeurs[1]).toEqual({ nom: 'Poulet', supplement: 600 });
  });

  it('lit « on » comme obligatoire, et rien d’autre', () => {
    // Le piège : `required` est la chaîne "on", pas un booléen. Un test de
    // véracité naïf rendrait obligatoires TOUTES les options.
    expect(transformerOptions(VIANDES)[0]?.obligatoire).toBe(true);

    const facultative = JSON.stringify([
      { name: 'Sauce', type: 'multi', values: [{ label: 'Piment', optionPrice: '0' }] },
    ]);
    expect(transformerOptions(facultative)[0]?.obligatoire).toBe(false);
  });

  it('recalcule min et max d’après le type', () => {
    // 6ammart laisse min et max à 0 même sur un choix unique obligatoire.
    const [unique] = transformerOptions(VIANDES);
    expect(unique?.minSelect).toBe(1);
    expect(unique?.maxSelect).toBe(1);

    const multiple = transformerOptions(
      JSON.stringify([
        {
          name: 'Suppléments',
          type: 'multi',
          required: '',
          values: [
            { label: 'Fromage', optionPrice: '200' },
            { label: 'Œuf', optionPrice: '300' },
          ],
        },
      ]),
    );
    expect(multiple[0]?.minSelect).toBe(0);
    expect(multiple[0]?.maxSelect).toBeGreaterThan(1);
  });

  it('ignore une option sans valeur', () => {
    // Elle rendrait le produit incommandable : la base refuse l'ajout au
    // panier tant qu'une option obligatoire n'a aucune valeur.
    expect(transformerOptions(JSON.stringify([{ name: 'Vide', values: [] }]))).toEqual([]);
  });

  it('encaisse un JSON invalide sans planter', () => {
    expect(transformerOptions('[{cassé')).toEqual([]);
    expect(transformerOptions('[]')).toEqual([]);
    expect(transformerOptions(null)).toEqual([]);
  });
});

describe('variantes e-commerce', () => {
  // « Viande de bœuf » : prix affiché 3 000 F, variantes de 1 250 à 3 000 F.
  const BOEUF = {
    choix: JSON.stringify([
      { name: 'choice_4', title: 'Quantité', options: ['1/2kg avec os', ' 1kg avec os'] },
    ]),
    variations: JSON.stringify([
      { type: '1/2kgavecos', price: 1250, stock: 999999 },
      { type: '1kgavecos', price: 2500, stock: 999999 },
    ]),
  };

  it('reconstruit un prix de base et des suppléments', () => {
    // 6ammart donne des prix ABSOLUS ; Tovo additionne base + supplément.
    // Le client doit payer exactement les mêmes montants qu'avant.
    const r = transformerVariantes(BOEUF.choix, BOEUF.variations, 3000);
    expect(r?.prix).toBe(1250);
    expect(r?.options[0]?.valeurs).toEqual([
      { nom: '1/2kg avec os', supplement: 0 },
      { nom: '1kg avec os', supplement: 1250 },
    ]);
    // Vérification par les totaux : 1250+0 et 1250+1250.
    expect(r!.options[0]!.valeurs.map((v) => r!.prix + v.supplement)).toEqual([1250, 2500]);
  });

  it('rapproche les libellés malgré les espaces', () => {
    // « 1/2kg avec os » côté choix, « 1/2kgavecos » côté variantes.
    expect(transformerVariantes(BOEUF.choix, BOEUF.variations, 3000)?.options[0]?.valeurs[1]?.supplement)
      .toBe(1250);
  });

  it('ne rend jamais un produit gratuit', () => {
    // Quand 6ammart n'a pas de prix par variante il écrit 0. Le prendre pour
    // un prix absolu offrirait le t-shirt à 8 000 F.
    const r = transformerVariantes(
      JSON.stringify([{ title: 'Couleur', options: ['Bleu'] }]),
      JSON.stringify([{ type: 'Bleu', price: 0, stock: 100 }]),
      8000,
    );
    expect(r?.prix).toBe(8000);
    expect(r?.options[0]?.valeurs[0]?.supplement).toBe(0);
  });

  it('refuse ce qu’il ne sait pas représenter', () => {
    // Deux attributs = prix par combinaison. Renvoyer null laisse le
    // chargeur signaler le produit plutôt qu'inventer une facturation.
    const deux = JSON.stringify([
      { title: 'Couleur', options: ['Rouge'] },
      { title: 'Taille', options: ['XL'] },
    ]);
    expect(transformerVariantes(deux, '[]', 100)).toBeNull();
    expect(transformerVariantes('[]', '[]', 100)).toBeNull();
    expect(transformerVariantes('{cassé', '[]', 100)).toBeNull();
  });

  it('marque le stock « illimité » comme non suivi', () => {
    // 999999 affiché tel quel donnerait « 999999 en stock » dans l'app.
    expect(stockUtile('999999')).toBeNull();
    expect(stockUtile('12')).toBe(12);
    expect(stockUtile('0')).toBeNull();
    expect(stockUtile(null)).toBeNull();
  });
});

describe('montants et libellés', () => {
  it('arrondit au franc le plus proche', () => {
    // Tronquer 1499,99 donnerait 1499 et ferait perdre un franc au
    // boutiquier à chaque vente.
    expect(versXof('1499.99')).toBe(1500);
    expect(versXof('2500.00')).toBe(2500);
    expect(versXof(null)).toBe(0);
    expect(versXof('-50')).toBe(0);
  });

  it('assemble un nom sans laisser passer « null »', () => {
    expect(nomComplet('Mohamedine', 'Abdallah')).toBe('Mohamedine Abdallah');
    expect(nomComplet('Issa', null)).toBe('Issa');
    expect(nomComplet('null', 'null')).toBe('');
  });

  it('extrait un délai de préparation d’une chaîne libre', () => {
    expect(delaiPreparation('30-40')).toBe(30);
    expect(delaiPreparation('20 min')).toBe(20);
    expect(delaiPreparation('bientôt')).toBe(20);
    expect(delaiPreparation(null)).toBe(20);
  });

  it('produit des slugs distincts pour un même nom', () => {
    // « Boissons » existe chez les restaurants et à l'épicerie ; le slug est
    // unique en base, une collision ferait échouer le chargement en cours.
    expect(slug('Boissons', '12')).toBe('boissons-12');
    expect(slug('Boissons', '34')).toBe('boissons-34');
    expect(slug('Épicerie & Frais', '7')).toBe('epicerie-frais-7');
    expect(slug('🍕', '9')).toBe('categorie-9');
  });
});
