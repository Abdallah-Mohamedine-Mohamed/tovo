import 'registry.dart';
import 'widgets/cards.dart';
import 'widgets/cart_summary.dart';
import 'widgets/category_grid.dart';
import 'widgets/courier_form.dart';
import 'widgets/image_search_prompt.dart';
import 'widgets/option_selector.dart';
import 'widgets/order_tracking.dart';
import 'widgets/price_comparison.dart';
import 'widgets/product_carousel.dart';
import 'widgets/quick_replies.dart';

/// Enregistre les composants du contrat auprès du registre.
///
/// À appeler une fois au démarrage, avant le premier rendu. C'est le seul
/// fichier qui change quand on ajoute un composant — `registry.dart` ne
/// bouge jamais, et un type non enregistré est simplement ignoré au lieu de
/// casser le fil.
///
/// Les douze composants du contrat v1 sont désormais tous implémentés.
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

    'product_card': (component, onInteraction) =>
        ProductCard(component: component, onInteraction: onInteraction),

    'merchant_card': (component, onInteraction) =>
        MerchantCard(component: component, onInteraction: onInteraction),

    'quick_replies': (component, onInteraction) =>
        QuickReplies(component: component, onInteraction: onInteraction),

    'cart_summary': (component, onInteraction) =>
        CartSummary(component: component, onInteraction: onInteraction),

    'option_selector': (component, onInteraction) =>
        OptionSelector(component: component, onInteraction: onInteraction),

    'order_tracking': (component, onInteraction) =>
        OrderTracking(component: component, onInteraction: onInteraction),

    'price_comparison': (component, onInteraction) =>
        PriceComparison(component: component, onInteraction: onInteraction),

    'image_search_prompt': (component, onInteraction) =>
        ImageSearchPrompt(component: component, onInteraction: onInteraction),

    'courier_form': (component, onInteraction) =>
        CourierForm(component: component, onInteraction: onInteraction),
  });
}
