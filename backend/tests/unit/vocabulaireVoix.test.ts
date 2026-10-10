import { describe, expect, it } from 'vitest';
import { quartiersDeNiamey, tropProches } from '../../src/services/voixDirecte.js';

describe('quartiers et enseignes cohabitent dans la liste de la transcription (09/10)', () => {
  it('un quartier trop proche d’une enseigne reste dehors (« Garbado » / « GARBA D’OR »)', () => {
    expect(tropProches('Garbado', "GARBA D'OR")).toBe(true);
    expect(tropProches('Garbado', 'Garbador')).toBe(true);
  });

  it('des noms assez différents cohabitent (« Bobiel » / « BOBA »)', () => {
    expect(tropProches('Bobiel', 'BOBA')).toBe(false);
    expect(tropProches('Yantala', "O'TAKOSS")).toBe(false);
  });

  it('les quartiers sont compactés : un nom qui en contient un autre n’ajoute rien', () => {
    const q = quartiersDeNiamey();
    expect(q).toContain('Bobiel');
    // « Boukoki 1 » à « Boukoki 4 » : un seul « Boukoki ».
    expect(q).toContain('Boukoki');
    expect(q).not.toContain('Boukoki 1');
  });
});

describe('un lieu mal transcrit est rattrapé, sans jamais deviner (10/10)', async () => {
  const { quartierApproche } = await import('../../src/services/lieux.js');
  it('« Gobien », « Gobiel » → Bobiel ; « Haroubanda » → Harobanda, même dans une phrase', () => {
    expect(quartierApproche('Gobien')?.nom).toBe('Bobiel');
    expect(quartierApproche('le restaurant AFC à Gobien')?.nom).toBe('Bobiel');
    expect(quartierApproche('chez ma tante à Gobien')?.nom).toBe('Bobiel');
    expect(quartierApproche('chez Moussa à Haroubanda')?.nom).toBe('Harobanda');
  });
  it('une phrase ordinaire, un prénom, un nom commun : rien n’est « corrigé »', () => {
    for (const t of ['la maison', 'comme ça', 'chez Moussa', 'à la gare', 'pharmacie']) expect(quartierApproche(t)).toBeNull();
  });
  it('deux lieux possibles dans la même phrase ne donnent pas une position arbitraire', () => {
    expect(quartierApproche('à Gobien et à Haroubanda')).toBeNull();
  });
});

describe('le bon nom de lieu DANS le texte transcrit (10/10)', async () => {
  const { corrigerLieuxDuTexte } = await import('../../src/services/lieux.js');
  const proteges = ["GARBA D'OR", 'RESTAURANT AFC', 'BOBA', "O'TAKOSS"];
  it('« à Gobien » → « à Bobiel » : le client lit le nom qu’il a dit', () => {
    expect(corrigerLieuxDuTexte('le restaurant AFC à Gobien.', proteges)).toBe('le restaurant AFC à Bobiel.');
    expect(corrigerLieuxDuTexte('chez Moussa à Haroubanda, vers Yantalla', proteges)).toBe('chez Moussa à Harobanda, vers Yantala');
  });
  it('rien d’autre n’est touché : une boutique, un prénom, un mot en minuscules', () => {
    for (const t of ["Je veux à tcheker chez GARBA D'OR.", 'Je veux parler à Madame Issa de la part de Moussa.',
      'Je veux un tacos à la viande de Poulet.', 'au grand marché', 'Je veux aller à Garba dort.',
      'Un colis vers Yantala Haut, de la part de Moussa.']) {
      expect(corrigerLieuxDuTexte(t, proteges)).toBe(t);
    }
  });
});
