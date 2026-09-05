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
    final actions =
        (component.data['actions'] as List?)?.whereType<String>().toList() ??
        const ['add_to_cart'];
    final disponible = component.flag('is_available', true);
    final id = component.str('id');

    return _Fiche(
      imageUrl: component.str('image_url').isEmpty
          ? null
          : component.str('image_url'),
      titre: component.str('name'),
      sousTitre: component.str('merchant_name'),
      description: component.str('description'),
      indisponible: !disponible,
      pied: Row(
        children: [
          Text(
            Money.format(component.money('price')),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: TovoTheme.tealDeep,
              letterSpacing: -0.4,
            ),
          ),
          const Spacer(),
          if (actions.contains('compare_price'))
            TextButton(
              onPressed: () => onInteraction(
                TovoInteraction('compare_price', {
                  'query': component.str('name'),
                }),
              ),
              child: const Text('Comparer', style: TextStyle(fontSize: 12)),
            ),
          if (actions.contains('add_to_cart'))
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
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
    final logo = component.str('logo_url');
    final adresse = component.str('address_hint');

    return Opacity(
      opacity: ouverte ? 1 : 0.72,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: id.isEmpty
              ? null
              : () => onInteraction(
                  TovoInteraction('select_merchant', {'merchant_id': id}),
                ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 82,
                  height: 82,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: _LogoBoutique(url: logo.isEmpty ? null : logo),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        component.str('name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: TovoTheme.ink,
                        ),
                      ),
                      if (adresse.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          adresse,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: TovoTheme.muted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Icon(
                            ouverte ? Icons.check_circle : Icons.schedule,
                            size: 14,
                            color: ouverte
                                ? TovoTheme.success
                                : TovoTheme.danger,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              ouverte
                                  ? 'Ouverte · ${component.money('prep_time_min', 20)} min'
                                  : 'Fermée',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: ouverte
                                    ? TovoTheme.success
                                    : TovoTheme.danger,
                              ),
                            ),
                          ),
                          if (distance != null) ...[
                            const Text(
                              '  ·  ',
                              style: TextStyle(color: TovoTheme.muted),
                            ),
                            Text(
                              Money.distance(distance.toInt()),
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: TovoTheme.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: TovoTheme.muted,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoBoutique extends StatelessWidget {
  const _LogoBoutique({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final repli = Container(
      color: TovoTheme.tealMist,
      alignment: Alignment.center,
      child: const Icon(
        Icons.storefront_outlined,
        color: TovoTheme.teal,
        size: 28,
      ),
    );
    if (url == null) return repli;

    return Image.network(
      url!,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => repli,
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
  });

  final String titre;
  final String sousTitre;
  final String description;
  final String? imageUrl;
  final bool indisponible;
  final Widget pied;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: indisponible ? 0.6 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
          boxShadow: TovoTheme.ombre,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Vignette(url: imageUrl, hauteur: 132),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titre,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.25,
                      color: TovoTheme.ink,
                    ),
                  ),
                  if (sousTitre.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sousTitre,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: TovoTheme.muted,
                      ),
                    ),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: TovoTheme.inkDoux,
                      ),
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
