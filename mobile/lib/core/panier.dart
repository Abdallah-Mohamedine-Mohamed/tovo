import 'package:flutter/foundation.dart';

import '../components/registry.dart';
import 'api.dart';

/// Ce que la pastille montre du panier : combien d'articles, pour combien.
@immutable
class ApercuPanier {
  const ApercuPanier({
    required this.articles,
    required this.total,
    required this.boutique,
    this.composant,
  });

  final int articles;

  /// Le prix des articles, sans la livraison (calculée à la commande).
  final int total;
  final String boutique;

  /// Le panier complet, pour ouvrir l'écran de commande sans attendre.
  final TovoComponent? composant;

  static ApercuPanier? depuis(TovoComponent panier) {
    final lignes = panier.list('items');
    final articles = lignes.fold<int>(
      0,
      (n, l) => n + ((l['quantity'] as num?)?.toInt() ?? 1),
    );
    if (articles == 0) return null;
    return ApercuPanier(
      articles: articles,
      total: panier.money('items_total'),
      boutique: panier.str('merchant_name'),
      composant: panier,
    );
  }
}

/// Le panier, partout et tout de suite.
///
/// Avant, après « Ajouter au panier », rien n'indiquait où il était : il
/// fallait le chercher dans le menu. Désormais, toute réponse du serveur qui
/// contient un panier le met à jour ici — quel que soit le geste qui l'a
/// modifié (fiche produit, « + » d'une grille, discussion, écran de
/// commande) — et la pastille suit.
class PanierEnDirect extends ValueNotifier<ApercuPanier?> {
  PanierEnDirect._() : super(null);

  static final PanierEnDirect instance = PanierEnDirect._();

  /// Appelé par [TovoApi] sur chaque réponse : un panier présent la met à
  /// jour. Une réponse sans panier ne dit en général rien du panier : on n'y
  /// touche pas. Sauf sur les routes du panier lui-même : le serveur n'y
  /// renvoie aucun panier quand il est vide (dernier article retiré,
  /// « vider »). Avant, la pastille gardait alors l'ancien article.
  void observer(TovoResponse reponse, {String? chemin}) {
    if (!reponse.ok) return;
    for (final composant in reponse.components) {
      if (composant.type == 'cart_summary') {
        value = ApercuPanier.depuis(composant);
        return;
      }
    }
    if (chemin == '/cart' || (chemin?.startsWith('/cart/') ?? false)) {
      value = null;
    }
  }

  /// Le panier est vide (dernier article retiré, commande passée).
  void vider() => value = null;

  /// Relit le panier, par exemple à l'ouverture de l'application.
  Future<void> rafraichir(TovoApi api) async {
    final reponse = await api.get('/cart');
    if (!reponse.ok) return;
    final panier = reponse.components
        .where((c) => c.type == 'cart_summary')
        .firstOrNull;
    value = panier == null ? null : ApercuPanier.depuis(panier);
  }
}
