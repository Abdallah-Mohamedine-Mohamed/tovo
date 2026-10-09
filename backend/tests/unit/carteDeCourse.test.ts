import { describe, expect, it } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { EXECUTORS } from '../../src/ai/tools.js';
import { avecPreuves, Faits, verifierTexte } from '../../src/ai/verificateur.js';

/** La base ne sert qu'au tarif ville : sans réponse, la carte reste sans prix. */
const db = { rpc: async () => ({ data: null, error: null }) } as unknown as SupabaseClient;
const position = { lat: 13.52, lng: 2.11 };
const preparer = (args: Record<string, unknown>, message = '') =>
  EXECUTORS.preparer_course!(args, { db, userId: 'u1', currentMessage: message, position });
const carte = (r: { components: Array<{ type: string; data: Record<string, unknown> }> }) =>
  r.components.find((c) => c.type === 'courier_form')?.data;

describe('la carte de course ne contredit jamais le trajet demandé (09/10, S4, R4)', () => {
  it('Harobanda → Banifandou : pas de carte « Commander », deux choix à la place', async () => {
    const r = await preparer({ mode: 'recuperer', ou_recuperer: 'Harobanda', arrivee: { hint: 'Banifandou' } });
    expect(carte(r)).toBeUndefined();
    const choix = r.components.find((c) => c.type === 'quick_replies')?.data.items as Array<{ label: string }>;
    expect(choix.map((c) => c.label)).toEqual(['Chercher à Harobanda, livrer chez moi', 'Venir chez moi, livrer à Banifandou']);
    expect((r.summary as Record<string, unknown>).carte_possible).toBe(false);
  });

  it('Harobanda → chez moi : la carte « Aller chercher »', async () => {
    const r = await preparer({ mode: 'recuperer', ou_recuperer: 'Harobanda', arrivee: { hint: 'chez moi' } });
    expect(carte(r)).toMatchObject({ mode: 'recuperer', pickup: { hint: 'Harobanda' } });
  });

  it('chez moi → Banifandou : la carte « Venir chez moi »', async () => {
    const r = await preparer({ mode: 'deposer', arrivee: { hint: 'Banifandou' } });
    expect(carte(r)).toMatchObject({ mode: 'deposer', dropoff: { hint: 'Banifandou' } });
  });

  it('« venir chez moi » avec un départ ailleurs devient « aller chercher » là-bas', async () => {
    const r = await preparer({ mode: 'deposer', depart: { hint: 'Harobanda' } });
    expect(carte(r)).toMatchObject({ mode: 'recuperer', pickup: { hint: 'Harobanda' } });
  });

  it('une consigne pour le livreur est dite NON transmise (la carte n’a pas de place pour elle)', async () => {
    const r = await preparer({ mode: 'deposer', arrivee: { hint: 'Banifandou' }, consigne: 'sonnez au portail bleu' });
    expect(r.summary).toMatchObject({ consigne_du_client: 'sonnez au portail bleu', consigne_transmise: false });
  });
});

describe('la nouvelle carte (contrat 2) : tout trajet, consigne comprise (09/10)', () => {
  // La base : le forfait ville, et le prix à la distance.
  const base = {
    rpc: async (nom: string) => (nom === 'courier_price'
      ? { data: 2750, error: null }
      : { data: { price: 1000, callback_minutes: 7 }, error: null }),
  } as unknown as SupabaseClient;
  const trajet = (args: Record<string, unknown>, consigne?: string) =>
    EXECUTORS.preparer_course!(args, {
      db: base, userId: 'u1', currentMessage: '', position, trajetLibre: true, ...(consigne ? { consigne } : {}),
    });

  it('Harobanda → Banifandou : la carte porte les deux lieux, situés, et le prix à la distance', async () => {
    const r = await trajet({ mode: 'recuperer', ou_recuperer: 'Harobanda', arrivee: { hint: 'Banifandou' } }, 'sonner au portail bleu');
    const d = carte(r)!;
    expect(d.mode).toBe('deposer');
    expect(d.pickup).toMatchObject({ chez_moi: false, hint: 'Harobanda' });
    expect(d.dropoff).toMatchObject({ chez_moi: false, hint: 'Banifandou' });
    expect(typeof (d.pickup as { lat?: unknown }).lat).toBe('number');
    expect(d.position).toEqual(position);
    expect(d.consigne).toBe('sonner au portail bleu');
    expect(d.estimate).toMatchObject({ price: 2750 });
  });

  it('aller chercher, livrer chez moi : le forfait (comme la base)', async () => {
    const r = await trajet({ mode: 'recuperer', ou_recuperer: 'chez Moussa à Harobanda', contact_sur_place: '90 12 34 56' });
    const d = carte(r)!;
    expect(d.mode).toBe('recuperer');
    expect(d.dropoff).toMatchObject({ chez_moi: true });
    expect(d.pickup_contact).toBe('90 12 34 56');
    expect(d.estimate).toMatchObject({ price: 1000, flat: true });
  });

  it('« à Niamey 2000, ici à ma position » : c’est chez le client, avec son quartier (09/10)', async () => {
    // Le client est à Niamey 2000 (centre du quartier dans OpenStreetMap).
    const { chargerLieux } = await import('../../src/services/lieux.js');
    const n2000 = chargerLieux().find((l) => l.genre === 'quartier' && l.nom === 'Niamey 2000')!;
    const r = await EXECUTORS.preparer_course!(
      { mode: 'recuperer', ou_recuperer: 'Bobiel', arrivee: { hint: 'Niamey 2000' } },
      {
        db: base, userId: 'u1', trajetLibre: true, position: { lat: n2000.lat, lng: n2000.lng },
        currentMessage: 'Je veux qu’un livreur aille chercher un colis à Bobiel et me l’amène à Niamey 2000, ici à ma position',
      },
    );
    const d = carte(r)!;
    expect(d.dropoff).toMatchObject({ chez_moi: true, quartier: 'Niamey 2000' });
    expect(d.pickup).toMatchObject({ chez_moi: false, hint: 'Bobiel' });
    expect(d.mode).toBe('recuperer');
  });

  it('« je veux un livreur » : départ chez moi, arrivée à préciser', async () => {
    const d = carte(await trajet({}))!;
    expect(d.pickup).toMatchObject({ chez_moi: true });
    expect(d.dropoff).toBeNull();
  });
});

describe('le vérificateur : « sera transmise », « avec votre consigne » (09/10, R5)', () => {
  it('retirés sans précision enregistrée', () => {
    const faits = new Faits();
    faits.ajouter({ consigne_transmise: false });
    expect(verifierTexte('Votre course est prête, avec votre consigne pour le portail bleu.', faits).texte).toBe('');
    expect(verifierTexte('Votre instruction sera transmise au livreur.', faits).texte).toBe('');
  });

  it('une consigne non transmise : toute tournure qui la dit prise en compte est retirée, la franchise reste', () => {
    const faits = new Faits();
    faits.ajouter({ consigne_du_client: 'sonner au portail bleu', consigne_transmise: false });
    const retire = (t: string) => verifierTexte(t, faits).texte === '';
    expect(retire('Touchez Commander le livreur pour qu’il vous appelle et prenne en compte votre consigne pour le portail bleu.')).toBe(true);
    expect(retire('Le livreur sonnera au portail bleu.')).toBe(true);
    expect(retire('Je ne peux pas encore transmettre votre consigne : dites-la au livreur quand il vous appellera.')).toBe(false);
    expect(retire('Voici votre course pour Banifandou.')).toBe(false);
  });

  it('« je m’occupe », « c’est lancé » : retirés tant qu’aucune commande n’existe', () => {
    const faits = new Faits();
    expect(verifierTexte('Avec plaisir, je m’occupe de récupérer votre sac à Yantala.', faits).texte).toBe('');
    expect(verifierTexte('C’est lancé !', faits).texte).toBe('');
    const commande = new Faits();
    commande.ajouter(avecPreuves({ order_id: 'o1' }, 'commande_existe'));
    expect(verifierTexte('C’est lancé !', commande).texte).not.toBe('');
  });

  it('gardés quand la précision est réellement enregistrée', () => {
    const faits = new Faits();
    faits.ajouter(avecPreuves({ note_de_commande: 'appelez en arrivant' }, 'precision_enregistree'));
    expect(verifierTexte('Votre instruction sera transmise au livreur.', faits).texte).not.toBe('');
  });
});
