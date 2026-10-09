import { describe, expect, it } from 'vitest';
import {
  argumentsDeLaCourse, CHEZ_LE_CLIENT, completerCourse, decrireMemoire, lireConversation, type Ligne,
} from '../../src/ai/conversation.js';

const maintenant = new Date('2026-10-09T18:00:00Z');
const il_y_a = (minutes: number) => new Date(maintenant.getTime() - minutes * 60_000).toISOString();
const tovo = (minutes: number, components: unknown[] = [], content = '') =>
  ({ role: 'assistant', content, components, created_at: il_y_a(minutes) }) satisfies Ligne;
const client = (minutes: number, content: string) => ({ role: 'user', content, created_at: il_y_a(minutes) }) satisfies Ligne;

const carteCourse = (data: Record<string, unknown>) => ({ type: 'courier_form', data });
const pizzas = {
  type: 'product_carousel',
  data: { items: [
    { id: 'p1', name: 'Pizza 3 Fromage', price: 5500, merchant_id: 'm1', merchant_name: 'MAISON GRILL' },
    { id: 'p2', name: 'Pizza Margerita', price: 5000, merchant_id: 'm1', merchant_name: 'MAISON GRILL' },
  ] },
};

describe('la mémoire de conversation (étape 4, 09/10)', () => {
  it('S1 : une question au milieu ne fait pas oublier la course', () => {
    // Du plus récent au plus ancien, comme la base les rend.
    const m = lireConversation([
      tovo(1, [], 'Le tarif dépend de la distance.'),
      client(2, 'c’est combien la livraison ?'),
      tovo(3, [carteCourse({ pickup: { chez_moi: true, hint: 'Chez le client' }, dropoff: null })]),
      client(4, 'Je veux un livreur'),
    ], maintenant);
    expect(m.tache).toMatchObject({ genre: 'course', course: { depart: CHEZ_LE_CLIENT, arrivee: null } });
    expect(decrireMemoire(m)).toContain('COURSE pas encore commandée');
  });

  it('S2 : un numéro ajouté complète la course sans perdre le lieu', () => {
    const m = lireConversation([
      tovo(1, [carteCourse({ mode: 'recuperer', pickup: { chez_moi: false, hint: 'chez ma tante à Yantala' }, dropoff: { chez_moi: true } })]),
    ], maintenant);
    expect(m.tache?.genre).toBe('course');
    if (m.tache?.genre !== 'course') throw new Error('pas de course');
    const course = completerCourse(m.tache.course, { telephone: '90 12 34 56' });
    expect(course).toMatchObject({ depart: 'chez ma tante à Yantala', arrivee: CHEZ_LE_CLIENT, contact_depart: '90 12 34 56' });
    expect(argumentsDeLaCourse(course)).toMatchObject({ mode: 'recuperer', ou_recuperer: 'chez ma tante à Yantala', contact_sur_place: '90 12 34 56' });
  });

  it('E3 : un lieu redit remplace l’ancien, le reste est gardé', () => {
    const course = completerCourse(
      { depart: CHEZ_LE_CLIENT, arrivee: 'Gamkalley', contact_depart: null, destinataire: '90000000', consigne: 'portail bleu' },
      { arrivee: 'Koira Kano' },
    );
    expect(course).toMatchObject({ arrivee: 'Koira Kano', destinataire: '90000000', consigne: 'portail bleu' });
  });

  it('S7 : un merci ne fait pas oublier la liste affichée', () => {
    const m = lireConversation([
      tovo(1, [], 'Avec plaisir !'),
      client(2, 'merci'),
      tovo(3, [{ type: 'commerces_hors_tovo', data: { items: [{ id: 'c1', nom: 'Amimi-Scarf' }, { id: 'c2', nom: 'Yallabai' }] } }]),
    ], maintenant);
    expect(m.ecran?.references.map((r) => r.nom)).toEqual(['Amimi-Scarf', 'Yallabai']);
    expect(decrireMemoire(m)).toContain('1. Amimi-Scarf (commerce hors Tovo)');
  });

  it('S5 : l’ordre de l’écran, boutique Tovo comprise', () => {
    const m = lireConversation([tovo(1, [
      { type: 'merchant_card', data: { id: 'b1', name: 'PARAPHARMACIE' } },
      { type: 'commerces_hors_tovo', data: { items: [{ id: 'c1', nom: 'Pharmacie Deyzeibon' }] } },
    ])], maintenant);
    expect(m.ecran?.references.map((r) => `${r.rang}. ${r.nom}`)).toEqual(['1. PARAPHARMACIE', '2. Pharmacie Deyzeibon']);
  });

  it('S8 : au-delà de 6 heures, plus rien ne compte', () => {
    const m = lireConversation([tovo(7 * 60, [pizzas])], maintenant);
    expect(m.ecran).toBeNull();
    expect(m.tache).toBeNull();
    expect(decrireMemoire(m)).toContain('Aucune tâche en cours');
  });

  it('S10 : le repas en cours garde sa boutique, même après une précision', () => {
    const m = lireConversation([
      tovo(1, [], 'Vous pourrez modifier cette précision dans votre panier.'),
      client(2, 'sans oignons'),
      tovo(3, [pizzas]),
    ], maintenant);
    expect(m.tache).toMatchObject({ genre: 'repas', boutique: { id: 'm1', nom: 'MAISON GRILL' } });
  });

  it('une course commandée (suivi affiché) ou éteinte n’est plus en cours', () => {
    expect(lireConversation([
      tovo(1, [{ type: 'order_tracking', data: { status: 'ready' } }]),
      tovo(2, [carteCourse({ pickup: { chez_moi: true } })]),
    ], maintenant).tache).toBeNull();
    expect(lireConversation([tovo(1, [carteCourse({ pickup: { chez_moi: true }, utilise: true })])], maintenant).tache).toBeNull();
  });

  it('une autre recherche (plusieurs boutiques) arrête le repas en cours', () => {
    const autre = { type: 'product_carousel', data: { items: [
      { id: 'a', name: 'Coca', merchant_id: 'm2', merchant_name: 'WORLD JUS' },
      { id: 'b', name: 'Coca', merchant_id: 'm3', merchant_name: 'BOBA' },
    ] } };
    expect(lireConversation([tovo(1, [autre]), tovo(3, [pizzas])], maintenant).tache).toBeNull();
  });
});
