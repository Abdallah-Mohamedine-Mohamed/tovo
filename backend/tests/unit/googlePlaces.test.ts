import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../src/config/env.js', () => ({ env: { GOOGLE_PLACE_API_KEY: 'cle-de-test' } }));

const { chercherSurGoogle, nomsCorrespondent } = await import('../../src/services/googlePlaces.js');

const lieu = (nom: string, extra: Record<string, unknown> = {}) => ({
  id: `place-${nom}`, displayName: { text: nom }, shortFormattedAddress: 'Bd de l’Indépendance, Niamey',
  location: { latitude: 13.504, longitude: 2.134 }, businessStatus: 'OPERATIONAL',
  nationalPhoneNumber: '20 73 61 60', primaryType: 'restaurant', ...extra,
});

function googleRepond(places: unknown[]) {
  const appel = vi.fn(async () => new Response(JSON.stringify({ places }), { status: 200 }));
  vi.stubGlobal('fetch', appel);
  return appel;
}

afterEach(() => vi.unstubAllGlobals());

describe('le complément Google (01/10)', () => {
  it('tolère les fautes et l’ordre des mots, pas un autre nom', () => {
    expect(nomsCorrespondent('Merguez Nouhou', 'Nouhou Merguez')).toBe(true);
    expect(nomsCorrespondent('Nouho', 'Nouhou Merguez')).toBe(true);
    expect(nomsCorrespondent('garbador', 'Garba d’Or')).toBe(true);
    expect(nomsCorrespondent('Tchos', 'Tchoco Bar')).toBe(false);
    expect(nomsCorrespondent('AFC', 'ABC')).toBe(false);
  });

  it('ne demande ni note, ni avis, ni photo', async () => {
    const appel = googleRepond([]);
    await chercherSurGoogle('Nouhou Merguez');
    const entetes = (appel.mock.calls[0] as unknown as [string, RequestInit])[1].headers as Record<string, string>;
    expect(entetes['X-Goog-FieldMask']).not.toMatch(/rating|review|photo/i);
  });

  it('garde seulement les lieux sûrs : même nom, en activité, à Niamey, pas un hôpital', async () => {
    googleRepond([
      lieu('Nouhou Merguez'),
      lieu('Tchoco Bar'),
      lieu('Nouhou Merguez 2', { businessStatus: 'CLOSED_PERMANENTLY' }),
      lieu('Nouhou Merguez Dakar', { location: { latitude: 14.7, longitude: -17.4 } }),
      lieu('Clinique Nouhou Merguez', { primaryType: 'hospital' }),
    ]);
    const r = await chercherSurGoogle('Nouhou Merguez');
    expect(r.map((c) => c.nom)).toEqual(['Nouhou Merguez']);
    expect(r[0]).toMatchObject({
      place_id: 'place-Nouhou Merguez', type: 'restaurant', adresse: 'Bd de l’Indépendance',
      telephone: '20 73 61 60', telephone_appel: '+22720736160', source: 'google',
    });
  });

  it('une pharmacie trouvée sur Google est montrée (incluses le 01/10)', async () => {
    googleRepond([lieu('Pharmacie Cité Fayçal', { primaryType: 'pharmacy' })]);
    const r = await chercherSurGoogle('pharmacie cite faycal');
    expect(r.map((c) => c.type)).toEqual(['pharmacie']);
  });

  it('Google en panne : rien, et jamais d’erreur', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('réseau'); }));
    expect(await chercherSurGoogle('Nouhou Merguez')).toEqual([]);
  });
});
