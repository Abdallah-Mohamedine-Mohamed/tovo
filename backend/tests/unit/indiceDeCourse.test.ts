import { describe, expect, it } from 'vitest';
import { indiceDeCourse } from '../../src/ai/intents.js';

describe('indiceDeCourse', () => {
  it('reconnaît une course', () => {
    for (const p of [
      'Je veux un livreur', 'envoie moi un coursier', 'envoyer un colis au Plateau',
      'va chercher mon paquet chez Moussa', 'récupérer un document', 'une moto vite',
    ]) expect(indiceDeCourse(p), p).toBe(true);
  });
  it('un livre, un livret, un produit : pas une course', () => {
    for (const p of ['Je cherche un livre', 'un livre de cuisine', 'je veux du riz', 'un livret scolaire'])
      expect(indiceDeCourse(p), p).toBe(false);
  });
});
