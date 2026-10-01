import { describe, expect, it, vi } from 'vitest';

const lignes = [
  { debut: '2026-09-26T07:00:00Z', fin: '2026-10-03T07:00:00Z', commune: 'I', nom: 'Avenir', localisation: 'Plateau, Avenue Maurice de Lens', telephone: '20753869', lat: 13.522, lng: 2.099, precision: 'quartier' },
  { debut: '2026-09-26T07:00:00Z', fin: '2026-10-03T07:00:00Z', commune: 'III', nom: 'Carrefour 6ème', localisation: 'Nouveau Marché, près Rond-Point 6ème', telephone: '20741818', lat: 13.503, lng: 2.1297, precision: 'pharmacie' },
  { debut: '2026-09-26T07:00:00Z', fin: '2026-10-03T07:00:00Z', commune: 'V', nom: 'Galabi', localisation: 'Saguia', telephone: '96484545', lat: null, lng: null, precision: null },
];

vi.mock('../../src/services/supabase.js', () => {
  const requete = {
    select: () => requete, lte: () => requete, gt: () => requete, order: () => requete,
    limit: async () => ({ data: lignes, error: null }),
  };
  return { serviceClient: () => ({ from: () => requete }) };
});

const { demandeDeGarde, heuresDeGarde, reponseGarde, oublierGarde } = await import('../../src/services/pharmaciesGarde.js');

describe('pharmacies de garde (01/10)', () => {
  it('reconnaît la demande, écrite ou venue de la carte de l’accueil', () => {
    expect(demandeDeGarde('Pharmacies de garde près de moi')).toBe(true);
    expect(demandeDeGarde('c’est quelle pharmacie de garde ce soir ?')).toBe(true);
    expect(demandeDeGarde('une pharmacie ouverte la nuit')).toBe(true);
    expect(demandeDeGarde('Je veux du paracétamol')).toBe(false);
  });

  it('la nuit et le dimanche, à l’heure de Niamey', () => {
    expect(heuresDeGarde(new Date('2026-10-01T21:30:00Z'))).toBe(true); // 22 h 30 à Niamey
    expect(heuresDeGarde(new Date('2026-10-01T10:00:00Z'))).toBe(false); // mercredi 11 h
    expect(heuresDeGarde(new Date('2026-10-04T10:00:00Z'))).toBe(true); // dimanche
  });

  it('les plus proches de la position d’abord, avec numéro et livreur', async () => {
    oublierGarde();
    const r = await reponseGarde({ lat: 13.504, lng: 2.134 }, 'hors-tovo-oui:');
    expect(r.content).toBe('Les pharmacies de garde les plus proches de vous, du samedi 26/09 8 h au samedi 03/10 8 h :');
    const items = r.components[0]?.data.items as Array<Record<string, unknown>>;
    expect(items.map((i) => i.nom)).toEqual(['Pharmacie Carrefour 6ème', 'Pharmacie Avenir', 'Pharmacie Galabi']);
    expect(items[0]).toMatchObject({ telephone: '20 74 18 18', telephone_appel: '+22720741818', icone: 'lieu-pharmacie', type: 'De garde · Commune III' });
    expect((items[0]!.livreur as { value: string }).value).toContain('|+22720741818');
    // Sans position connue : pas de distance.
    expect(items[2]!.distance_m).toBeNull();
  });

  it('sans position : la liste, et l’invitation à partager sa position', async () => {
    oublierGarde();
    const r = await reponseGarde(null, 'hors-tovo-oui:');
    expect(r.content).toContain('Partagez votre position');
  });
});
