import { describe, expect, it } from 'vitest';
import { messageClient } from '../../src/services/orderNotifications.js';

/**
 * Un repas et un colis ne se racontent pas pareil. Avant : « Votre commande
 * va être récupérée » pour un colis, « Bon appétit ! » à sa livraison, et
 * rien quand le livreur le prenait.
 */
describe('messageClient — un repas', () => {
  const repas = { type: 'delivery', boutique: "Garba d'Or", livreur: 'Moussa', total: 4500, especes: true };

  it('raconte la commande avec la boutique et le livreur', () => {
    expect(messageClient({ ...repas, statut: 'confirmed' })?.corps).toBe("Garba d'Or prépare votre commande.");
    expect(messageClient({ ...repas, statut: 'assigned' })?.corps).toBe("Moussa va récupérer votre commande chez Garba d'Or.");
  });

  it('rappelle la somme à préparer quand le livreur arrive, en espèces', () => {
    expect(messageClient({ ...repas, statut: 'delivering' })?.corps).toBe('Moussa est en route vers vous. Préparez 4500 F en espèces.');
    expect(messageClient({ ...repas, statut: 'delivering', especes: false })?.corps).toBe('Moussa est en route vers vous.');
  });

  it('souhaite bon appétit à la livraison', () => {
    expect(messageClient({ ...repas, statut: 'delivered' })?.titre).toBe('Bon appétit !');
  });

  it('se tait sur les étapes sans intérêt pour le client', () => {
    for (const statut of ['pending', 'preparing', 'ready', 'picked_up']) {
      expect(messageClient({ ...repas, statut })).toBeNull();
    }
  });

  it('sans livreur connu, dit « Votre livreur »', () => {
    expect(messageClient({ ...repas, livreur: null, statut: 'assigned' })?.corps).toMatch(/^Votre livreur va récupérer/);
  });
});

describe('messageClient — un colis', () => {
  const colis = { type: 'courier', livreur: 'Awa', total: 1000, especes: true };

  it('« venir chez moi » : le livreur arrive chez le client, puis part livrer', () => {
    expect(messageClient({ ...colis, mode: 'deposer', statut: 'assigned' })?.corps).toBe('Awa arrive chez vous pour prendre le colis.');
    const pris = messageClient({ ...colis, mode: 'deposer', statut: 'picked_up' });
    expect(pris?.titre).toBe('Colis récupéré');
    expect(pris?.corps).toBe('Awa a votre colis et part le livrer.');
    expect(messageClient({ ...colis, mode: 'deposer', statut: 'delivered' })?.titre).toBe('Colis livré');
  });

  it('« aller chercher » : le livreur part le chercher, puis l’apporte', () => {
    expect(messageClient({ ...colis, mode: 'recuperer', statut: 'assigned' })?.corps).toBe('Awa part chercher votre colis.');
    expect(messageClient({ ...colis, mode: 'recuperer', statut: 'picked_up' })?.corps)
      .toBe('Awa a votre colis et vous l’apporte. Préparez 1000 F en espèces.');
    expect(messageClient({ ...colis, mode: 'recuperer', statut: 'delivered' })?.titre).toBe('Colis reçu');
  });

  it('ne souhaite jamais « bon appétit » pour un colis', () => {
    for (const mode of ['deposer', 'recuperer']) {
      for (const statut of ['assigned', 'picked_up', 'delivering', 'delivered', 'cancelled']) {
        const m = messageClient({ ...colis, mode, statut });
        expect(`${m?.titre} ${m?.corps}`).not.toMatch(/appétit|commande va être/i);
      }
    }
  });

  it('un seul message entre « récupéré » et « en route »', () => {
    expect(messageClient({ ...colis, mode: 'deposer', statut: 'delivering' })).toBeNull();
  });
});
