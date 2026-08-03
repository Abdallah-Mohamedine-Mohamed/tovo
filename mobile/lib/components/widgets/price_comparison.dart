import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `price_comparison` — comparateur de prix.
///
/// Deux natures de résultats cohabitent, et la distinction n'est pas
/// négociable : une boutique partenaire se commande, une offre externe se
/// consulte. Les présenter pareil ferait croire à l'utilisateur qu'il peut
/// commander chez Jumia depuis Tovo — il découvrirait le contraire après
/// avoir tapé, ce qui est le pire moment.
class PriceComparison extends StatelessWidget {
  const PriceComparison({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final resultats = component.list('results');
    if (resultats.isEmpty) return const SizedBox.shrink();

    // Partenaires d'abord, du moins cher au plus cher. C'est le classement
    // qui sert l'utilisateur ET le produit : ce qu'il peut réellement
    // commander vient en premier.
    final partenaires = resultats.where((r) => r['is_orderable'] == true).toList()
      ..sort((a, b) => _prix(a).compareTo(_prix(b)));
    final externes = resultats.where((r) => r['is_orderable'] != true).toList()
      ..sort((a, b) => _prix(a).compareTo(_prix(b)));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x12000000)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: TovoTheme.tealSoft,
            child: Text(
              component.str('product_query'),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: TovoTheme.teal,
              ),
            ),
          ),

          for (var i = 0; i < partenaires.length; i++)
            _Ligne(
              donnee: partenaires[i],
              meilleure: i == 0,
              onInteraction: onInteraction,
            ),

          if (externes.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: TovoTheme.surface,
              child: const Text(
                'Ailleurs — hors livraison Tovo',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: TovoTheme.muted,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            for (final externe in externes)
              _Ligne(donnee: externe, meilleure: false, onInteraction: onInteraction),
          ],
        ],
      ),
    );
  }

  static int _prix(Map<String, dynamic> r) => (r['price'] as num?)?.toInt() ?? 0;
}

class _Ligne extends StatelessWidget {
  const _Ligne({
    required this.donnee,
    required this.meilleure,
    required this.onInteraction,
  });

  final Map<String, dynamic> donnee;
  final bool meilleure;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final commandable = donnee['is_orderable'] == true;
    final enStock = donnee['in_stock'] != false;
    final distance = (donnee['distance_m'] as num?)?.toInt();

    return Opacity(
      opacity: enStock ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: TovoTheme.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          (donnee['seller_name'] as String?) ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (meilleure) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: TovoTheme.tealSoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'meilleur prix',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: TovoTheme.teal,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      (donnee['product_name'] as String?) ?? '',
                      if (distance != null) Money.distance(distance),
                      if (!enStock) 'rupture',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              Money.format((donnee['price'] as num?)?.toInt() ?? 0),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: meilleure ? TovoTheme.teal : TovoTheme.ink,
              ),
            ),
            const SizedBox(width: 8),
            // Bouton plein pour ce qui se commande, bouton discret pour ce
            // qu'on ne peut que consulter. La forme dit ce que le texte
            // seul ne suffirait pas à faire comprendre au premier regard.
            commandable
                ? FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: enStock
                        ? () => onInteraction(
                              TovoInteraction('select_product', {
                                'product_id': donnee['ref_id'],
                              }),
                            )
                        : null,
                    child: const Text('Commander', style: TextStyle(fontSize: 11)),
                  )
                : TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: () => onInteraction(
                      TovoInteraction('open_external', {'url': donnee['source_url']}),
                    ),
                    child: const Text('Voir', style: TextStyle(fontSize: 11)),
                  ),
          ],
        ),
      ),
    );
  }
}
