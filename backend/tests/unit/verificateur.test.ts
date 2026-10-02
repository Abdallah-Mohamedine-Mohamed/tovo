import { describe, expect, it } from 'vitest';
import { Faits, FluxVerifie, verifierTexte } from '../../src/ai/verificateur.js';

/** Ce que les outils ont renvoyé pendant le tour. */
function faitsDuTour(): Faits {
  const faits = new Faits();
  faits.ajouter('je veux un tacos');
  faits.ajouter({
    resultats: 2,
    produits: [
      { id: 'p1', name: 'Royal tacos', price: 6000, merchant_name: 'Royal grill steak house' },
      { id: 'p2', name: 'Tacos au poulet', price: 3500, merchant_name: "O'takoss (centre aéré)" },
    ],
  });
  faits.ajouter({ callback_minutes: 7, total: 6800 });
  return faits;
}

describe('le vérificateur : aucun fait inventé ne part', () => {
  it('laisse passer ce que la base a donné', () => {
    const texte = 'Le **Royal tacos** est à 6 000 F. Un livreur vous appelle dans les 7 minutes.';
    const v = verifierTexte(texte, faitsDuTour());
    expect(v.texte).toBe(texte);
    expect(v.retirees).toEqual([]);
  });

  it('retire la phrase au prix inventé, garde le reste', () => {
    const v = verifierTexte('Voici ce que je trouve. Le Royal tacos est à 4 500 F.', faitsDuTour());
    expect(v.texte).toBe('Voici ce que je trouve.');
    expect(v.retirees[0]!.inventees).toEqual([{ genre: 'montant', valeur: '4 500 F' }]);
  });

  it('retire une durée inventée', () => {
    const v = verifierTexte('Votre commande arrive dans 15 minutes.', faitsDuTour());
    expect(v.texte).toBe('');
    expect(v.retirees[0]!.inventees[0]!.genre).toBe('duree');
  });

  it('retire un plat mis en avant qui n’existe pas au catalogue', () => {
    const v = verifierTexte('Je vous recommande le **Tacos géant au fromage**. Bon appétit !', faitsDuTour());
    expect(v.texte).toBe('Bon appétit !');
    expect(v.retirees[0]!.inventees).toEqual([{ genre: 'nom', valeur: 'Tacos géant au fromage' }]);
  });

  it('un nom approché d’un vrai produit passe (accord de l’essentiel des mots)', () => {
    expect(verifierTexte('Le **tacos poulet** est disponible.', faitsDuTour()).retirees).toEqual([]);
  });

  it('un compte en gras doit être le vrai compte', () => {
    expect(verifierTexte('**2 résultats** pour votre recherche.', faitsDuTour()).retirees).toEqual([]);
    expect(verifierTexte('**241 produits** correspondent.', faitsDuTour()).texte).toBe('');
  });

  it('les écritures de montant : 6800 F, 6.800 FCFA, 6 800 francs', () => {
    const f = faitsDuTour();
    for (const t of ['Total : 6800 F.', 'Total : 6.800 FCFA.', 'Total : 6 800 francs.']) {
      expect(verifierTexte(t, f).retirees).toEqual([]);
    }
  });

  it('une réponse sans fait (salutation, question) passe telle quelle', () => {
    const texte = 'Bonjour ! Que souhaitez-vous commander aujourd’hui ?';
    expect(verifierTexte(texte, new Faits()).texte).toBe(texte);
  });
});

describe('le flux vérifié : phrase par phrase', () => {
  it('une phrase ne part que complète et vérifiée', () => {
    const emis: string[] = [];
    const flux = new FluxVerifie(faitsDuTour(), (t) => emis.push(t));
    for (const morceau of ['Voici le Roy', 'al tacos à 6 0', '00 F. Et le Monster ', 'à 9 000 F. Bon', ' appétit !']) {
      flux.pousser(morceau);
    }
    flux.terminer();
    expect(emis.join('')).toBe('Voici le Royal tacos à 6 000 F. Bon appétit !');
    expect(flux.retirees.map((r) => r.inventees[0]!.valeur)).toEqual(['9 000 F']);
  });
});

describe('les mots du client (évaluation externe, 02/10)', () => {
  it('reconnaissent un nom, jamais un nombre ni une durée', () => {
    const faits = new Faits();
    faits.ajouterParole('Il arrive dans 10 minutes ? Et le **poulet braisé** coûte 5000 F ?');
    // La durée et le prix ne viennent que de la question : refusés.
    expect(verifierTexte('Votre livreur arrive dans 10 minutes.', faits).texte).toBe('');
    expect(verifierTexte('Il coûte 5 000 F.', faits).texte).toBe('');
    // Le nom, lui, est bien celui que le client a dit.
    expect(verifierTexte('Je cherche du **poulet braisé** pour vous.', faits).texte).toContain('poulet braisé');
  });
});

describe('article 4 de la constitution : rien n’est dit fait s’il ne l’est pas', () => {
  it('« noté », « transmis » seulement si les données le confirment', () => {
    expect(verifierTexte('Bien noté pour sans oignons !', new Faits()).texte).toBe('');
    expect(verifierTexte('Je l’ai transmis à l’équipe.', new Faits()).texte).toBe('');
    const garde = new Faits();
    garde.ajouter({ precision: 'sans oignons', enregistree: true });
    expect(verifierTexte('C’est noté : sans oignons.', garde).texte).toContain('noté');
    // Un conseil n'est pas une affirmation.
    expect(verifierTexte('Vous pouvez noter votre adresse.', new Faits()).texte).toContain('noter');
  });
  it('« en route » seulement si une commande existe', () => {
    expect(verifierTexte('Un livreur se rend à votre position.', new Faits()).texte).toBe('');
    const suivi = new Faits();
    suivi.ajouter({ order_id: 'c1', status: 'picked_up' });
    expect(verifierTexte('Votre livreur est en route.', suivi).texte).toContain('en route');
  });
});

describe('article 4 : « annulé » seulement si une annulation a eu lieu', () => {
  it('sans commande annulée, la phrase est retirée', () => {
    expect(verifierTexte('Ça marche, c’est annulé.', new Faits()).texte).toBe('');
    const annulee = new Faits();
    annulee.ajouter({ order_id: 'c1', status: 'cancelled' });
    expect(verifierTexte('Votre commande a été annulée.', annulee).texte).toContain('annulée');
  });
});
