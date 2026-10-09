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
