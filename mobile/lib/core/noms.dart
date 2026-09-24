/// Les noms d'articles et d'enseignes, tels qu'on les affiche.
///
/// Une seule majuscule, au début (choix du client, 25/09) : les catalogues
/// importés mélangent « GARBA D'OR », « American Breakfast » et « Pizza
/// cannibale » ; côte à côte, ça crie. En phrase, tout se lit pareil.
///
///   « GARBA D'OR »                → « Garba d'or »
///   « American Breakfast »        → « American breakfast »
///   « O'TAKOSS ( Centre Aéré ) »  → « O'takoss (centre aéré) »
String enPhrase(String? nom) {
  final propre = (nom ?? '')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('( ', '(')
      .replaceAll(' )', ')');
  if (propre.isEmpty) return propre;
  final bas = propre.toLowerCase();
  return bas[0].toUpperCase() + bas.substring(1);
}
