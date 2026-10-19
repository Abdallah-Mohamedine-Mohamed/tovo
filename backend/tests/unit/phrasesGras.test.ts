import { describe, expect, it } from 'vitest';
import { phrases } from '../../src/ai/verificateur.js';

describe('découpe en phrases', () => {
  it('ne coupe jamais à l’intérieur d’un nom en gras (« **St. Ives** »)', () => {
    expect(phrases("Je n'ai pas la lotion **St. Ives** Vitamine E. Voici des laits proches."))
      .toEqual(["Je n'ai pas la lotion **St. Ives** Vitamine E. ", 'Voici des laits proches.']);
  });

  it('coupe toujours après un point hors gras, et à un retour à la ligne', () => {
    expect(phrases('Prix : 6.800 F. Livré ce soir.')).toEqual(['Prix : 6.800 F. ', 'Livré ce soir.']);
    expect(phrases('Un **gras orphelin.\nSuite.')).toEqual(['Un **gras orphelin.\n', 'Suite.']);
  });
});
