import { describe, expect, it } from 'vitest';
import { OtpDeliveryError, toWhatsAppNumber, vautLaPeineDeReessayer } from '../../src/services/whatsapp.js';

/**
 * La règle de réessai à l'envoi du code de connexion.
 *
 * Elle décide de deux inconforts opposés. Ne pas retenter, c'est afficher
 * « erreur de connexion » pour un ralentissement réseau d'une seconde —
 * fréquent ici. Retenter à tort, c'est envoyer deux codes : le premier reçu
 * n'est plus valable, le client saisit celui qu'il a lu en premier, et se
 * retrouve bloqué sans comprendre.
 *
 * Le critère n'est donc pas « est-ce transitoire » mais « le message a-t-il
 * pu partir malgré l'erreur ».
 */
describe('réessai d’envoi WhatsApp', () => {
  const erreur = (status: number) => new OtpDeliveryError('test', status);

  it('retente quand la connexion n’a pas abouti', () => {
    // 502 : rien n'est parti, aucun risque de doublon.
    expect(vautLaPeineDeReessayer(erreur(502))).toBe(true);
  });

  it('retente quand Meta répond en erreur serveur', () => {
    expect(vautLaPeineDeReessayer(erreur(500))).toBe(true);
    expect(vautLaPeineDeReessayer(erreur(503))).toBe(true);
  });

  it('ne retente PAS après notre propre délai dépassé', () => {
    // 504 : la requête peut très bien être arrivée chez Meta. Retenter
    // enverrait un second code et invaliderait le premier.
    expect(vautLaPeineDeReessayer(erreur(504))).toBe(false);
  });

  it('ne retente pas ce qui échouera pareil', () => {
    // Modèle inconnu, numéro invalide, jeton expiré : la seconde réponse
    // serait identique, une seconde plus tard.
    expect(vautLaPeineDeReessayer(erreur(400))).toBe(false);
    expect(vautLaPeineDeReessayer(erreur(401))).toBe(false);
    expect(vautLaPeineDeReessayer(erreur(404))).toBe(false);
    expect(vautLaPeineDeReessayer(erreur(429))).toBe(false);
  });
});

describe('numéro au format Meta', () => {
  it('retire le « + » et les séparateurs', () => {
    expect(toWhatsAppNumber('+227 86 96 79 08')).toBe('22786967908');
    // Supabase Auth enregistre déjà sans le « + » : les deux formes doivent
    // donner le même résultat, sinon la moitié des envois partiraient à un
    // numéro mal formé.
    expect(toWhatsAppNumber('22786967908')).toBe('22786967908');
  });

  it('refuse ce qui ne peut pas être un numéro', () => {
    expect(() => toWhatsAppNumber('123')).toThrow(OtpDeliveryError);
  });
});
