import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../src/config/env.js', () => ({ env: { GOOGLE_ROUTES_API_KEY: 'cle-test' } }));

const { decoderPolyline, itinerairePour, surLeTrace, viderCacheItineraires } = await import(
  '../../src/services/itineraire.js'
);

// L'exemple de la documentation Google : (38.5,-120.2) (40.7,-120.95) (43.252,-126.453).
const EXEMPLE = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';

function reponseGoogle(polyline = EXEMPLE) {
  return new Response(
    JSON.stringify({ routes: [{ polyline: { encodedPolyline: polyline }, distanceMeters: 1200, duration: '240s' }] }),
    { status: 200 },
  );
}

describe('itinéraires de la carte de suivi', () => {
  afterEach(() => {
    viderCacheItineraires();
    vi.restoreAllMocks();
  });

  it('décode une polyligne Google', () => {
    const points = decoderPolyline(EXEMPLE);
    expect(points).toHaveLength(3);
    expect(points[0]).toEqual({ lat: 38.5, lng: -120.2 });
    expect(points[2]!.lat).toBeCloseTo(43.252, 5);
    expect(points[2]!.lng).toBeCloseTo(-126.453, 5);
  });

  it('lit les consignes de navigation, étape par étape (guidage vocal, 07/10)', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(JSON.stringify({ routes: [{
      polyline: { encodedPolyline: EXEMPLE }, distanceMeters: 1200, duration: '240s',
      legs: [{ steps: [
        { navigationInstruction: { instructions: 'Prendre la direction  nord', maneuver: 'DEPART' }, distanceMeters: 300,
          startLocation: { latLng: { latitude: 13.53, longitude: 2.09 } } },
        { navigationInstruction: { instructions: 'Tourner à gauche sur Boulevard de la Jeunesse', maneuver: 'TURN_LEFT' }, distanceMeters: 900,
          startLocation: { latLng: { latitude: 13.533, longitude: 2.09 } } },
        { distanceMeters: 10 },
      ] }],
    }] }), { status: 200 }));
    const it = await itinerairePour('carte:x', { lat: 13.53, lng: 2.09 }, { lat: 13.54, lng: 2.08 });
    expect(it?.etapes).toEqual([
      { instruction: 'Prendre la direction nord', manoeuvre: 'DEPART', distanceM: 300, debut: { lat: 13.53, lng: 2.09 } },
      { instruction: 'Tourner à gauche sur Boulevard de la Jeunesse', manoeuvre: 'TURN_LEFT', distanceM: 900, debut: { lat: 13.533, lng: 2.09 } },
    ]);
  });

  it('sait si le livreur est encore sur le tracé', () => {
    const trace = [{ lat: 13.5, lng: 2.1 }, { lat: 13.51, lng: 2.1 }];
    expect(surLeTrace({ lat: 13.5002, lng: 2.1 }, trace)).toBe(true);
    expect(surLeTrace({ lat: 13.5, lng: 2.11 }, trace)).toBe(false);
  });

  it('un tracé suivi ne se repaie pas tant que le livreur reste dessus', async () => {
    const appel = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => reponseGoogle());
    const destination = { lat: 43.252, lng: -126.453 };
    const t0 = 1_000_000;
    const livreur = { lat: 38.5, lng: -120.2 };
    const a = await itinerairePour('c1:approche', livreur, destination, { suivi: livreur, maintenant: t0 });
    const bouge = { lat: 38.5001, lng: -120.2 };
    const b = await itinerairePour('c1:approche', bouge, destination, { suivi: bouge, maintenant: t0 + 60_000 });
    expect(a?.dureeS).toBe(240);
    expect(b).toEqual(a);
    expect(appel).toHaveBeenCalledTimes(1);
  });

  it('un tracé fixe (boutique → client) ne se calcule qu’une fois', async () => {
    const appel = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => reponseGoogle());
    const boutique = { lat: 13.5, lng: 2.1 };
    const client = { lat: 13.52, lng: 2.12 };
    await itinerairePour('c4:trajet', boutique, client, { maintenant: 1_000_000 });
    await itinerairePour('c4:trajet', boutique, client, { maintenant: 1_000_000 + 30 * 60_000 });
    expect(appel).toHaveBeenCalledTimes(1);
  });

  it('hors du tracé : recalcule, mais jamais plus d’une fois par 20 s', async () => {
    const appel = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => reponseGoogle());
    const destination = { lat: 43.252, lng: -126.453 };
    const t0 = 1_000_000;
    const depart = { lat: 38.5, lng: -120.2 };
    await itinerairePour('c2:trajet', depart, destination, { suivi: depart, maintenant: t0 });
    const ailleurs = { lat: 30, lng: -100 };
    await itinerairePour('c2:trajet', ailleurs, destination, { suivi: ailleurs, maintenant: t0 + 5_000 });
    expect(appel).toHaveBeenCalledTimes(1);
    await itinerairePour('c2:trajet', ailleurs, destination, { suivi: ailleurs, maintenant: t0 + 25_000 });
    expect(appel).toHaveBeenCalledTimes(2);
  });

  it('Google injoignable : null, sans planter', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('réseau'));
    const r = await itinerairePour('c3:trajet', { lat: 13.5, lng: 2.1 }, { lat: 13.52, lng: 2.12 });
    expect(r).toBeNull();
  });
});
