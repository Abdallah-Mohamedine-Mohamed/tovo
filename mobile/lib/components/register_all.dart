import 'registry.dart';
import 'widgets/cart_summary.dart';
import 'widgets/category_grid.dart';
import 'widgets/product_carousel.dart';
import 'widgets/quick_replies.dart';

/// Enregistre les composants du contrat auprès du registre.
///
/// À appeler une fois au démarrage, avant le premier rendu. C'est le seul
/// fichier qui change quand on ajoute un composant — `registry.dart` ne
/// bouge jamais, et un type non enregistré est simplement ignoré au lieu de
/// casser le fil.
void registerTovoComponents() {
  ComponentRegistry.registerAll({
    'category_grid': (component, onInteraction) =>
        CategoryGrid(component: component, onInteraction: onInteraction),

    'product_carousel': (component, onInteraction) => ProductCollection(
          component: component,
          onInteraction: onInteraction,
          horizontal: true,
        ),

    'product_list': (component, onInteraction) => ProductCollection(
          component: component,
          onInteraction: onInteraction,
          horizontal: false,
        ),

    'quick_replies': (component, onInteraction) =>
        QuickReplies(component: component, onInteraction: onInteraction),

    'cart_summary': (component, onInteraction) =>
        CartSummary(component: component, onInteraction: onInteraction),

    // À venir : option_selector, product_card, merchant_card,
    // order_tracking, price_comparison, image_search_prompt, courier_form.
    // Tant qu'ils ne sont pas là, le backend peut déjà les émettre : le
    // registre les ignore sans planter.
  });
}
