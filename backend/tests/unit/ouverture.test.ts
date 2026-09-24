import { describe, expect, it } from 'vitest';
import { maintenantANiamey, ouverteMaintenant } from '../../src/services/ouverture.js';

// Jeudi 24/09/2026, 12 h 30 à Niamey = 11 h 30 UTC.
const MIDI_TRENTE = new Date('2026-09-24T11:30:00Z');
const JEUDI = 4;

describe('ouverture réelle : interrupteur ET horaires, à l’heure de Niamey', () => {
  it('Niamey est à UTC+1, sans heure d’été', () => {
    expect(maintenantANiamey(MIDI_TRENTE)).toEqual({ jour: JEUDI, heure: '12:30:00' });
    // 23 h 30 UTC le mercredi : déjà jeudi à Niamey.
    expect(maintenantANiamey(new Date('2026-09-23T23:30:00Z')).jour).toBe(JEUDI);
  });

  it('dans ses horaires du jour : ouverte', () => {
    expect(ouverteMaintenant(true, [{ day: JEUDI, opens_at: '11:00:00', closes_at: '15:00:00' }], MIDI_TRENTE)).toBe(true);
  });

  it('hors horaires : fermée, même interrupteur sur « ouvert »', () => {
    expect(ouverteMaintenant(true, [{ day: JEUDI, opens_at: '18:00:00', closes_at: '23:00:00' }], MIDI_TRENTE)).toBe(false);
    // Horaires d'un autre jour seulement.
    expect(ouverteMaintenant(true, [{ day: 5, opens_at: '08:00:00', closes_at: '20:00:00' }], MIDI_TRENTE)).toBe(false);
  });

  it('interrupteur sur « fermé » : fermée, quels que soient les horaires', () => {
    expect(ouverteMaintenant(false, [{ day: JEUDI, opens_at: '00:00:00', closes_at: '23:59:59' }], MIDI_TRENTE)).toBe(false);
  });

  it('sans horaires déclarés : l’interrupteur fait foi (comme en base)', () => {
    expect(ouverteMaintenant(true, [], MIDI_TRENTE)).toBe(true);
  });
});
