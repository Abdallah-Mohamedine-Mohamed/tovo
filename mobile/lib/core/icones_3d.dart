/// Les icônes 3D des catégories et des rayons, à la Glovo.
///
/// Fluent Emoji de Microsoft (licence MIT, assets/icons/3d/LICENSE),
/// embarquées : elles s'affichent avant le réseau.
class Icones3d {
  const Icones3d._();

  static const String _dossier = 'assets/icons/3d';

  /// Les catégories du catalogue, par slug (clé stable, voir
  /// IconesCategories).
  static const Map<String, String> _parSlug = {
    'restaurants-m3': 'burger',
    'grocery-m4': 'supermarche',
    'kasuwa-m10': 'marche',
    'kasuwa-1-m9': 'marche',
    'beaute-soins': 'beaute',
    'electronique': 'electronique',
    'vetements': 'vetements',
    'gaz-m12': 'gaz',
    'parapharmacies-m5': 'parapharmacie',
    'boutiques-m2': 'boutiques',
    'tovo-market-m8': 'colis',
    'street-food-m11': 'street-food',
    'billetterie-evenements-m13': 'billetterie',
    'repas': 'repas',
  };

  /// Les rayons des boutiques n'ont pas de slug : on reconnaît leur nom.
  /// L'ordre compte — « boissons chaudes » avant « boissons », « box poulet
  /// pané » est du poulet.
  static const List<(String, String)> _parMot = [
    ('burger', 'burger'),
    ('pizza', 'pizza'),
    ('chawarma', 'chawarma'),
    ('shawarma', 'chawarma'),
    ('sandwich', 'sandwich'),
    ('tacos', 'tacos'),
    ('grillade', 'grillades'),
    ('brochette', 'grillades'),
    ('poulet', 'poulet'),
    ('chicken', 'poulet'),
    ('volaille', 'viande'),
    ('viande', 'viande'),
    ('salade', 'salade'),
    ('crepe', 'crepes'),
    ('boissons chaudes', 'boisson-chaude'),
    ('cafe', 'boisson-chaude'),
    ('jus', 'jus'),
    ('soda', 'jus'),
    ('boisson', 'boissons'),
    ('petit dej', 'petit-dejeuner'),
    ('riz', 'riz'),
    ('pates', 'riz'),
    ('biscuit', 'biscuits'),
    ('bonbon', 'biscuits'),
    ('chocolat', 'biscuits'),
    ('conserve', 'conserves'),
    ('oeuf', 'oeufs'),
    ('farine', 'oeufs'),
    ('legume', 'legumes'),
    ('fruit', 'fruits'),
    ('poisson', 'poisson'),
    ('glace', 'glaces'),
    ('bebe', 'bebe'),
    ('beaute', 'beaute'),
    ('hygiene', 'hygiene'),
    ('epice', 'epices'),
    ('huile', 'epices'),
    ('sauce', 'epices'),
    ('pain', 'pain'),
    ('boulang', 'pain'),
    ('frite', 'frites'),
    ('dessert', 'desserts'),
    ('gateau', 'desserts'),
    ('entree', 'entrees'),
    ('plat', 'plats'),
  ];

  static String? categorie(String? slug) {
    final nom = _parSlug[slug];
    return nom == null ? null : '$_dossier/$nom.png';
  }

  static String? rayon(String nom) {
    final texte = _sansAccents(nom.toLowerCase());
    for (final (mot, icone) in _parMot) {
      if (texte.contains(mot)) return '$_dossier/$icone.png';
    }
    return null;
  }

  static String _sansAccents(String texte) {
    const avec = 'àâäéèêëîïôöùûüç';
    const sans = 'aaaeeeeiioouuuc';
    final tampon = StringBuffer();
    for (final c in texte.split('')) {
      final i = avec.indexOf(c);
      tampon.write(i < 0 ? c : sans[i]);
    }
    return tampon.toString();
  }
}
