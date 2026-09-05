import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `cart_summary` — récapitulatif du panier.
///
/// Les totaux affichés viennent tels quels du backend. Ce widget ne
/// recalcule rien : un total additionné côté app finirait par diverger de
/// celui qui est réellement facturé.
class CartSummary extends StatelessWidget {
  const CartSummary({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final items = component.list('items');
    final peutCommander = component.flag('can_checkout');
    final blocage = component.str('blocked_reason');
    final merchant = component.str('merchant_name');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        boxShadow: TovoTheme.ombreFlottante,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (merchant.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
              color: TovoTheme.tealDeep,
              child: Row(
                children: [
                  const Icon(
                    Icons.shopping_bag_rounded,
                    size: 17,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      merchant,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (final item in items)
            _Ligne(data: item, onInteraction: onInteraction),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              children: [
                _Total(
                  libelle: 'Sous-total',
                  montant: component.money('items_total'),
                ),
                _Total(
                  libelle: 'Livraison',
                  montant: component.money('delivery_fee'),
                ),
                const SizedBox(height: 6),
                _Total(
                  libelle: 'Total',
                  montant: component.money('total'),
                  fort: true,
                ),
                const SizedBox(height: 16),
                if (!peutCommander && blocage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      blocage,
                      style: const TextStyle(
                        fontSize: 12,
                        color: TovoTheme.danger,
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: peutCommander
                      ? () =>
                            onInteraction(const TovoInteraction('place_order'))
                      : null,
                  child: Text(
                    component.str(
                      'checkout_label',
                      'Commander — ${Money.format(component.money('total'))}',
                    ),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.data, required this.onInteraction});

  final Map<String, dynamic> data;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final itemId = data['item_id'] as String?;
    final quantite = (data['quantity'] as num?)?.toInt() ?? 1;
    final label = (data['selections_label'] as String?) ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (data['product_name'] as String?) ?? '',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: TovoTheme.ink,
                  ),
                ),
                if (label.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: TovoTheme.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (itemId != null)
            _Stepper(
              quantite: quantite,
              onChanged: (valeur) => onInteraction(
                TovoInteraction(
                  valeur == 0 ? 'remove_from_cart' : 'update_qty',
                  valeur == 0
                      ? {'item_id': itemId}
                      : {'item_id': itemId, 'quantity': valeur},
                ),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            Money.format((data['line_total'] as num?)?.toInt() ?? 0),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: TovoTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.quantite, required this.onChanged});

  final int quantite;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Bouton(
          icone: quantite > 1 ? Icons.remove : Icons.delete_outline,
          onTap: () => onChanged(quantite - 1),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '$quantite',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        _Bouton(icone: Icons.add, onTap: () => onChanged(quantite + 1)),
      ],
    );
  }
}

class _Bouton extends StatelessWidget {
  const _Bouton({required this.icone, required this.onTap});

  final IconData icone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: const BoxDecoration(
          color: TovoTheme.tealMist,
          shape: BoxShape.circle,
        ),
        child: Icon(icone, size: 15, color: TovoTheme.teal),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({
    required this.libelle,
    required this.montant,
    this.fort = false,
  });

  final String libelle;
  final int montant;
  final bool fort;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: fort ? 18 : 12.5,
      fontWeight: fort ? FontWeight.w800 : FontWeight.w400,
      color: fort ? TovoTheme.tealDeep : TovoTheme.muted,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(libelle, style: style),
          Text(Money.format(montant), style: style),
        ],
      ),
    );
  }
}
