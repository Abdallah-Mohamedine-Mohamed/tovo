import { describe, expect, it } from 'vitest';
import { tronquer } from '../../src/services/indexer.js';

/**
 * La troncature du texte indexé.
 *
 * Couper un emoji en deux ne lève aucune erreur côté JavaScript : c'est la
 * base qui refuse la requête, et l'indexeur reprend le produit indéfiniment
 * sans que personne ne s'en aperçoive. Le seul contrôle utile est de vérifier
 * que le résultat s'encode en UTF-8 valide.
 */

const utf8Valide = (s: string) => Buffer.from(s, 'utf8').toString('utf8') === s;

describe('troncature du texte indexé', () => {
  it('laisse un texte court intact', () => {
    expect(tronquer('Pommes Mangues', 500)).toBe('Pommes Mangues');
  });

  it('coupe à la longueur demandée', () => {
    expect(tronquer('a'.repeat(600), 500)).toHaveLength(500);
  });

  it('ne coupe pas un emoji en deux', () => {
    // 🍎 occupe deux unités UTF-16. Couper entre elles laisse une moitié
    // orpheline : le corps de la requête devient un UTF-8 invalide et
    // PostgREST répond « Empty or invalid json ».
    const texte = `${'a'.repeat(499)}🍎🥭✨`;
    const coupe = tronquer(texte, 500);

    expect(coupe).toHaveLength(499);
    expect(utf8Valide(coupe)).toBe(true);
    expect(utf8Valide(texte.slice(0, 500))).toBe(false); // ce que faisait l'ancien code
  });

  it('garde l’emoji quand il tient entier', () => {
    const texte = `${'a'.repeat(498)}🍎🥭`;
    const coupe = tronquer(texte, 500);

    expect(coupe).toBe(`${'a'.repeat(498)}🍎`);
    expect(utf8Valide(coupe)).toBe(true);
  });

  it('encaisse les accents, qui ne tiennent que sur une unité', () => {
    const texte = `${'é'.repeat(600)}`;
    expect(tronquer(texte, 500)).toHaveLength(500);
    expect(utf8Valide(tronquer(texte, 500))).toBe(true);
  });
});
