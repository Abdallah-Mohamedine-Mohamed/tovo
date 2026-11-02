import { describe, expect, it } from 'vitest';
import { construireSalle, debutDuJourANiamey, etapeDe, mediane, type CommandeBrute, type DonneesBrutes } from '../../src/services/salleControle.js';

const MAINTENANT = Date.parse('2026-11-06T18:42:00Z'); // 19 h 42 à Niamey
const il_y_a = (min: number) => new Date(MAINTENANT - min * 60_000).toISOString();

function commande(id: string, status: string, placeeIlYa: number, extra: Partial<CommandeBrute> = {}): CommandeBrute {
  return {
    id, type: 'delivery', status, total: 7500, delivery_fee: 1000,
    placed_at: il_y_a(placeeIlYa), delivered_at: null, scheduled_for: null, cancelled_reason: null,
    dropoff_hint: 'Koira Kano, près de la mosquée', lat: 13.53, lng: 2.12,
    merchant_id: 'gondwana', driver_id: null, client_nom: 'Aïcha Moussa', client_tel: '22790000000',
    historique: [{ status: 'pending', le: il_y_a(placeeIlYa) }], ...extra,
  };
}

const base = (): DonneesBrutes => ({
  commandes: [],
  boutiques: [
    { id: 'gondwana', nom: 'Le Gondwana', tel: '22791111111', lat: 13.52, lng: 2.11, ouverte: true },
    { id: 'otakoss', nom: 'O’Takoss', tel: null, lat: 13.51, lng: 2.10, ouverte: true },
  ],
  livreurs: [
    { id: 'ali', nom: 'Ali Issa', tel: null, en_ligne: true, disponible: true, vu_le: il_y_a(1), lat: 13.52, lng: 2.13 },
    { id: 'sani', nom: 'Sani', tel: null, en_ligne: false, disponible: true, vu_le: il_y_a(30), lat: null, lng: null },
  ],
  signalements: [],
});

describe('salle de contrôle', () => {
  const jour = debutDuJourANiamey(MAINTENANT);

  it('commence la journée à minuit, heure de Niamey', () => {
    expect(new Date(jour).toISOString()).toBe('2026-11-05T23:00:00.000Z');
  });

  it('une commande non acceptée depuis 9 min sonne, avec le numéro de la boutique', () => {
    const d = base();
    d.commandes = [commande('a', 'pending', 9)];
    const salle = construireSalle(d, MAINTENANT, jour);
    expect(salle.alertes).toHaveLength(1);
    expect(salle.alertes[0]).toMatchObject({ type: 'pas_acceptee', gravite: 'orange', depuis_min: 9 });
    expect(salle.alertes[0]!.action).toEqual({ libelle: 'Appeler la boutique', tel: '22791111111' });
    expect(salle.alertes[0]!.detail).toContain('Le Gondwana n’a pas répondu à la commande de Aïcha (Koira Kano');
    expect(salle.boutiques[0]).toMatchObject({ nom: 'Le Gondwana', note: 'Ne répond pas depuis 9 min' });
  });

  it('pas d’alerte avant 5 min, ni pour une commande programmée plus tard', () => {
    const d = base();
    d.commandes = [
      commande('a', 'pending', 3),
      commande('b', 'pending', 20, { scheduled_for: new Date(MAINTENANT + 2 * 3_600_000).toISOString() }),
    ];
    expect(construireSalle(d, MAINTENANT, jour).alertes).toEqual([]);
  });

  it('prête sans livreur : donne la distance du livreur libre le plus proche', () => {
    const d = base();
    d.commandes = [commande('a', 'ready', 30, {
      historique: [{ status: 'pending', le: il_y_a(30) }, { status: 'confirmed', le: il_y_a(28) }, { status: 'ready', le: il_y_a(12) }],
    })];
    const [alerte] = construireSalle(d, MAINTENANT, jour).alertes;
    expect(alerte).toMatchObject({ type: 'sans_livreur', gravite: 'rouge', depuis_min: 12 });
    expect(alerte!.detail).toMatch(/plus proche est à \d+,\d km/);
  });

  it('les chiffres du jour : livrées, durée médiane, chiffre, motifs d’annulation', () => {
    const d = base();
    d.commandes = [
      commande('l1', 'delivered', 120, { delivered_at: il_y_a(80), driver_id: 'ali' }),
      commande('l2', 'delivered', 100, { delivered_at: il_y_a(50) }),
      commande('x', 'cancelled', 90, { cancelled_reason: 'Produit non disponible' }),
      commande('hier', 'delivered', 24 * 60, { delivered_at: il_y_a(23 * 60) }),
    ];
    const { chiffres, livreurs } = construireSalle(d, MAINTENANT, jour);
    expect(chiffres).toMatchObject({ commandes: 3, livrees: 2, duree_mediane_min: 45, annulees: 1, chiffre_affaires: 15000, livraison: 2000, livreurs_en_ligne: 1, livreurs_libres: 1 });
    expect(chiffres.motifs_annulation).toEqual([{ motif: 'produit non disponible', nombre: 1 }]);
    expect(livreurs[0]).toMatchObject({ nom: 'Ali Issa', etat: 'libre', courses_du_jour: 1 });
    expect(livreurs[1]).toMatchObject({ etat: 'hors_ligne', detail: 'Hors ligne depuis 30 min' });
  });

  it('les alertes rouges d’abord, et un signalement ouvert attend une réponse', () => {
    const d = base();
    d.commandes = [commande('a', 'pending', 6), commande('b', 'pending', 15)];
    d.signalements = [{ id: 's', message: 'Ma commande n’est pas arrivée', le: il_y_a(40), order_id: null, client_nom: 'Fati', client_tel: null }];
    const salle = construireSalle(d, MAINTENANT, jour);
    expect(salle.alertes.map((a) => a.gravite)).toEqual(['rouge', 'rouge', 'orange']);
    expect(salle.alertes[0]!.type).toBe('signalement');
    expect(salle.en_cours[0]).toMatchObject({ id: 'b', en_alerte: true, etape: 0 });
  });

  it('un article manquant sans réponse du client devient une alerte, avec son numéro', () => {
    const d = base();
    d.commandes = [commande('a', 'pending', 3)];
    d.manquants = [{ id: 'm', order_id: 'a', nom: 'Pizza Double Fromage', le: il_y_a(6) }];
    const [alerte] = construireSalle(d, MAINTENANT, jour).alertes;
    expect(alerte).toMatchObject({ type: 'article_manquant', gravite: 'rouge', depuis_min: 6 });
    expect(alerte!.action).toEqual({ libelle: 'Appeler le client', tel: '22790000000' });
    expect(alerte!.detail).toContain('n’a plus de Pizza Double Fromage');
  });

  it('les étapes et la médiane', () => {
    expect(['pending', 'preparing', 'ready', 'delivering', 'delivered'].map(etapeDe)).toEqual([0, 1, 2, 3, 4]);
    expect(mediane([])).toBeNull();
    expect(mediane([3, 1, 2])).toBe(2);
  });
});
