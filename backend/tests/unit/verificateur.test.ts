import { describe, expect, it } from 'vitest';
import { avecPreuves, Faits, FluxVerifie, verifierTexte } from '../../src/ai/verificateur.js';

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
    garde.ajouter(avecPreuves({ precision: 'sans oignons' }, 'precision_enregistree'));
    expect(verifierTexte('C’est noté : sans oignons.', garde).texte).toContain('noté');
    // Un conseil n'est pas une affirmation.
    expect(verifierTexte('Vous pouvez noter votre adresse.', new Faits()).texte).toContain('noter');
  });
  it('les anciens champs devinés ne prouvent plus rien (étape 3, 09/10)', () => {
    const devine = new Faits();
    devine.ajouter({ enregistree: true, signale: true, order_id: 'c1', livreur_assigne: true, annulee: true });
    expect(verifierTexte('C’est noté.', devine).texte).toBe('');
    expect(verifierTexte('Votre livreur est en route.', devine).texte).toBe('');
    expect(verifierTexte('C’est annulé.', devine).texte).toBe('');
  });
  it('« en route » seulement si un livreur bouge VRAIMENT (la carte de suivi le dit)', () => {
    expect(verifierTexte('Un livreur se rend à votre position.', new Faits()).texte).toBe('');
    const attente = new Faits();
    attente.composant({ type: 'order_tracking', data: { order_id: 'c1', status: 'ready' } });
    expect(verifierTexte('Votre livreur est en route.', attente).texte).toBe('');
    const suivi = new Faits();
    suivi.composant({ type: 'order_tracking', data: { order_id: 'c1', status: 'picked_up', driver: { name: 'Moussa' } } });
    expect(verifierTexte('Votre livreur est en route.', suivi).texte).toContain('en route');
  });
  it('« c’est dans votre panier » seulement si l’article y est', () => {
    expect(verifierTexte('C’est dans votre panier.', new Faits()).texte).toBe('');
    // S10, relu le 09/10 : « C'est ajouté. », sans rien d'ajouté.
    expect(verifierTexte('C’est ajouté. Vous trouverez votre boisson chez O’Takoss.', new Faits()).texte).not.toContain('ajouté');
    expect(verifierTexte('C’est fait.', new Faits()).texte).toBe('');
    const annulee = new Faits();
    annulee.ajouter(avecPreuves({}, 'commande_annulee'));
    expect(verifierTexte('C’est fait, votre commande est annulée.', annulee).texte).not.toBe('');
    const panier = new Faits();
    panier.ajouter(avecPreuves({ total: 3500 }, 'ajoute_au_panier'));
    expect(verifierTexte('C’est dans votre panier.', panier).texte).not.toBe('');
  });
  it('« la carte qui s’affiche », « ci-dessous » seulement avec une carte (S1)', () => {
    expect(verifierTexte('Ajustez l’adresse sur la carte qui s’affiche.', new Faits()).texte).toBe('');
    const carte = new Faits();
    carte.composant({ type: 'courier_form', data: {} });
    expect(verifierTexte('Touchez le bouton ci-dessous.', carte).texte).not.toBe('');
  });
});

describe('article 4 : « annulé » seulement si une annulation a eu lieu', () => {
  it('sans commande annulée, la phrase est retirée', () => {
    expect(verifierTexte('Ça marche, c’est annulé.', new Faits()).texte).toBe('');
    const annulee = new Faits();
    annulee.composant({ type: 'order_tracking', data: { order_id: 'c1', status: 'cancelled' } });
    expect(verifierTexte('Votre commande a été annulée.', annulee).texte).toContain('annulée');
  });
});

describe('articles 12 à 14 de la constitution', () => {
  it('12 — aucune dose ni posologie', () => {
    expect(verifierTexte('Prenez 500 mg trois fois par jour.', new Faits()).texte).toBe('');
    expect(verifierTexte('Je vous conseille le Doliprane.', new Faits()).texte).toBe('');
    expect(verifierTexte('Une pharmacie de garde peut vous renseigner.', new Faits()).texte).toContain('pharmacie');
  });
  it('13 — un numéro seulement s’il vient des données ou du client', () => {
    const faits = new Faits();
    faits.ajouter({ telephone: '20 73 67 90' });
    faits.ajouterParole('rappelez-moi au 96 11 22 33');
    expect(verifierTexte('Appelez-la au 20 73 67 90.', faits).texte).toContain('20 73 67 90');
    expect(verifierTexte('Je vous rappelle au 96 11 22 33.', faits).texte).toContain('96 11 22 33');
    expect(verifierTexte('Votre voisin a le 90 44 55 66.', faits).texte).toBe('');
  });
  it('14 — toujours le vouvoiement', () => {
    expect(verifierTexte('Si tu as besoin, je suis là.', new Faits()).texte).toBe('');
    expect(verifierTexte('La boutique Tutti Frutti est ouverte.', new Faits()).texte).toContain('Tutti');
  });
});

describe('article 12 : un conseil n’est médical que s’il porte sur un médicament', () => {
  it('« je vous recommande le tacos » et les poids et volumes restent permis', () => {
    expect(verifierTexte('Je vous recommande le tacos.', new Faits()).texte).toContain('tacos');
    expect(verifierTexte('Un sac de riz de 500 g ou un Coca de 330 ml.', new Faits()).texte).toContain('500 g');
  });
});

describe('article 5 : « près de vous » seulement sous 2 km', () => {
  it('à 3 km, la phrase est retirée ; à 800 m, elle est gardée', () => {
    const loin = new Faits();
    loin.ajouter({ commerces: [{ nom: 'Nouhou Merguez', distance_m: 3138 }] });
    expect(verifierTexte('Nouhou Merguez est situé à proximité.', loin).texte).toBe('');
    const proche = new Faits();
    proche.ajouter({ commerces: [{ nom: 'Papayo', distance_m: 810 }] });
    expect(verifierTexte('Papayo est tout près de vous.', proche).texte).toContain('Papayo');
  });
});

describe('article 8 : n’envoyer vers un type de commerce que s’il est montré', () => {
  it('sans commerce montré, « consultez les librairies » est retiré ; avec, il reste', () => {
    expect(verifierTexte('Je vous invite à consulter les librairies spécialisées de Niamey.', new Faits()).texte).toBe('');
    const montres = new Faits();
    montres.ajouter({ commerces_hors_tovo: [{ nom: 'Pharmacie Deyzeibon', distance_m: 380 }] });
    expect(verifierTexte('Vous trouverez probablement ce médicament dans ces pharmacies.', montres).texte).toContain('pharmacies');
    // Une phrase ordinaire n'est pas touchée.
    expect(verifierTexte('Je n’ai pas de livres dans le catalogue pour le moment.', new Faits()).texte).toContain('livres');
  });
});

describe('article 5 : « près de vous » est faux quand on cherche autour d’un autre lieu', () => {
  it('les distances partent de Yantala : « près de vous » est retiré, « près de Yantala » reste', () => {
    const faits = new Faits();
    faits.ajouter({ distances_depuis_le_lieu: true, commerces_hors_tovo: [{ nom: 'Amimi-Scarf', distance_m: 530 }] });
    expect(verifierTexte('Amimi-Scarf est tout près de vous.', faits).texte).toBe('');
    expect(verifierTexte('Amimi-Scarf est à 530 m de Yantala.', faits).texte).toContain('Yantala');
  });
});

describe('les distances partent du client, jamais du lieu cherché (07/10)', () => {
  it('« à 3,2 km de Yantala » est retiré ; « à 3,2 km » et « vers Yantala » restent', () => {
    const faits = new Faits();
    faits.ajouter({ autour_de: 'Yantala Bas', commerces_hors_tovo: [{ nom: 'Second Life Africa', distance: '3,2 km' }] });
    expect(verifierTexte('Second Life Africa est la plus proche, située à 3,2 km de Yantala.', faits).texte).toBe('');
    expect(verifierTexte('Second Life Africa, vers Yantala, est à 3,2 km de vous.', faits).texte).toContain('3,2 km');
  });
});
