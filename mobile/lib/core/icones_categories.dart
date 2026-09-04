/// Les icônes de catégories embarquées dans l'application.
///
/// La table associe le `slug` d'une catégorie à son dessin. Le slug, et non
/// l'identifiant ni le nom : l'UUID obligerait à republier l'application si
/// la base était réamorcée, et le nom change — « Grocery » est le seul
/// intitulé anglais du catalogue et finira renommé.
///
/// Les slugs portent le suffixe de leur module d'origine (`-m3`, `-m8`) :
/// ils viennent de la reprise depuis 6ammart, où chaque module avait son
/// numéro. C'est laid mais c'est stable, et une clé stable vaut mieux qu'une
/// clé jolie.
class IconesCategories {
  const IconesCategories._();

  static const String _dossier = 'assets/icons/categories';

  /// Le repli quand aucune icône n'est prévue.
  ///
  /// Volontairement gris et neutre : une icône de secours colorée se ferait
  /// passer pour un vrai dessin, et personne ne remarquerait qu'il en manque
  /// un.
  static const String generique = '$_dossier/generique.svg';

  static const Map<String, String> _parSlug = {
    'boutiques-m2': '$_dossier/boutiques.svg',
    'restaurants-m3': '$_dossier/restaurants.svg',
    'grocery-m4': '$_dossier/grocery.svg',
    'parapharmacies-m5': '$_dossier/parapharmacies.svg',
    'tovo-market-m8': '$_dossier/tovo-market.svg',
    'street-food-m11': '$_dossier/street-food.svg',
    'billetterie-evenements-m13': '$_dossier/billetterie.svg',

    // Kasuwa et Kasuwa 1 partagent le même dessin : ce sont deux modules
    // identiques hérités de la migration, avec les mêmes sous-catégories.
    // Deux icônes différentes laisseraient croire à deux choses différentes.
    // Kasuwa est devenu « Marché » et Kasuwa 1 a été fondu dedans
    // (migration 0046). Le slug ne change pas — il porte l'identifiant du
    // module 6ammart, et le renommer ferait perdre l'icône. L'étal
    // convient toujours : c'est bien le marché qu'on y dessine.
    'kasuwa-m10': '$_dossier/kasuwa.svg',
    'kasuwa-1-m9': '$_dossier/kasuwa.svg',

    // Portes ouvertes en 0047, sur des PRODUITS et non des boutiques :
    // personne ne choisit son enseigne avant son shampoing.
    'beaute-soins': '$_dossier/beaute.svg',
    'vetements': '$_dossier/vetements.svg',
    'electronique': '$_dossier/electronique.svg',

    // Le gaz existait comme module vide depuis la migration ; il a reçu ses
    // bouteilles en 0047, en venant de « Tovo market ».
    'gaz-m12': '$_dossier/gaz.svg',
  };

  /// L'icône d'une catégorie, ou `null` s'il n'y en a pas de prévue.
  static String? pour(String? slug) {
    if (slug == null || slug.isEmpty) return null;
    return _parSlug[slug];
  }
}
