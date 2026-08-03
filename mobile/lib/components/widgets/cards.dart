import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `product_card` et `merchant_card` — deux fiches, un même fichier.
///
/// Elles partagent leur structure : une vignette, un titre, une ligne de
/// contexte, une action. Les séparer en deux fichiers dupliquerait la mise
/// en page sans rien clarifier.

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final actions = (component.data['actions'] as List?)?.whereType<String>().toList() ??
        const ['add_to_cart'];
    final disponible = component.flag('is_available', true);
    final id = component.str('id');

    return _Fiche(
      imageUrl: component.str('image_url').isEmpty ? null : component.str('image_url'),
      titre: component.str('name'),
      sousTitre: component.str('merchant_name'),
      description: component.str('description'),
      indisponible: !disponible,
      pied: Row(
        children: [
          Text(
            Money.format(component.money('price')),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: TovoTheme.teal,
            ),
          ),
          const Spacer(),
          if (actions.contains('compare_price'))
            TextButton(
              onPressed: () => onInteraction(
                TovoInteraction('compare_price', {'query': component.str('name')}),
              ),
              child: const Text('Comparer', style: TextStyle(fontSize: 12)),
            ),
          if (actions.contains('add_to_cart'))
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              // Un produit indisponible garde son bouton, désactivé : le
              // faire disparaître laisserait croire à un défaut d'affichage.
              onPressed: disponible && id.isNotEmpty
                  ? () => onInteraction(
                        TovoInteraction('add_to_cart', {
                          'product_id': id,
                          'quantity': 1,
                          'selections': const [],
                        }),
                      )
                  : null,
              child: Text(disponible ? 'Ajouter' : 'Indisponible'),
            ),
        ],
      ),
    );
  }
}

class MerchantCard extends StatelessWidget {
  const MerchantCard({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final ouverte = component.flag('is_open');
    final distance = component.data['distance_m'] as num?;
    final id = component.str('id');

    return _Fiche(
      imageUrl: component.str('logo_url').isEmpty ? null : component.str('logo_url'),
      hauteurImage: 96,
      titre: component.str('name'),
      sousTitre: [
        component.str('address_hint'),
        if (distance != null) Money.distance(distance.toInt()),
      ].where((s) => s.isNotEmpty).join(' · '),
      description: component.str('description'),
      indisponible: !ouverte,
      pied: Row(
        children: [
          Icon(
            ouverte ? Icons.check_circle : Icons.schedule,
            size: 15,
            color: ouverte ? TovoTheme.success : TovoTheme.danger,
          ),
          const SizedBox(width: 5),
          Text(
            ouverte
                ? 'Ouverte · ${component.money('prep_time_min', 20)} min'
                : 'Fermée',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ouverte ? TovoTheme.success : TovoTheme.danger,
            ),
          ),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: id.isEmpty
                ? null
                : () => onInteraction(
                      TovoInteraction('select_merchant', {'merchant_id': id}),
                    ),
            child: const Text('Voir'),
          ),
        ],
      ),
    );
  }
}

/// Structure commune aux deux fiches.
class _Fiche extends StatelessWidget {
  const _Fiche({
    required this.titre,
    required this.pied,
    this.imageUrl,
    this.sousTitre = '',
    this.description = '',
    this.indisponible = false,
    this.hauteurImage = 132,
  });

  final String titre;
  final String sousTitre;
  final String description;
  final String? imageUrl;
  final bool indisponible;
  final double hauteurImage;
  final Widget pied;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: indisponible ? 0.6 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
          border: Border.all(color: const Color(0x12000000)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Vignette(url: imageUrl, hauteur: hauteurImage),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titre,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: TovoTheme.ink,
                    ),
                  ),
                  if (sousTitre.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sousTitre,
                      style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                    ),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ],
                  const SizedBox(height: 14),
                  pied,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Vignette extends StatelessWidget {
  const _Vignette({required this.url, required this.hauteur});

  final String? url;
  final double hauteur;

  @override
  Widget build(BuildContext context) {
    // Un carré tramé plutôt qu'une icône d'erreur : sur un réseau instable,
    // l'image manque souvent, et une erreur affichée ferait croire à une
    // panne alors que tout le reste fonctionne.
    final placeholder = Container(
      height: hauteur,
      color: const Color(0xFFEBEBEB),
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, color: Color(0xFFBDBDBD)),
    );

    if (url == null || url!.isEmpty) return placeholder;

    return Image.network(
      url!,
      height: hauteur,
      width: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
}
