import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/catalog_image.dart';
import '../../core/viewport_reveal.dart';
import '../registry.dart';

/// Les produits trouvés, dans le fil.
///
/// Une grille de deux colonnes, et non plus un carrousel : dans un carrousel
/// on voyait un produit et demi, le reste caché hors de l'écran — « 38
/// produits » annoncés, deux visibles, et rien ne disait qu'il fallait
/// glisser. Ici, quatre produits d'un coup d'œil, et le reste à un geste.
///
/// Le « + » sur la photo ajoute au panier sans ouvrir la fiche. Un produit à
/// personnaliser ouvre sa fiche : ses options ne se devinent pas.
class ProductCollection extends StatefulWidget {
  const ProductCollection({
    super.key,
    required this.component,
    required this.onInteraction,
    required this.horizontal,
  });
  final TovoComponent component;
  final InteractionCallback onInteraction;

  /// Vrai pour `product_carousel` (la grille), faux pour `product_list`.
  final bool horizontal;

  @override
  State<ProductCollection> createState() => _ProductCollectionState();
}

class _ProductCollectionState extends State<ProductCollection> {
  static const _visibles = 4;
  bool _tout = false;

  @override
  Widget build(BuildContext context) {
    final component = widget.component;
    final onInteraction = widget.onInteraction;
    // Les indisponibles en dernier : on ne propose pas d'abord ce qu'on ne
    // peut pas commander. `sort` est stable, l'ordre de pertinence tient.
    final items = [...component.list('items')]
      ..sort(
        (a, b) =>
            (a['is_available'] == false ? 1 : 0) -
            (b['is_available'] == false ? 1 : 0),
      );
    if (items.isEmpty) return const SizedBox.shrink();
    final browse = component.map('browse');
    final montres = _tout || items.length <= _visibles
        ? items
        : items.take(_visibles).toList();
    final caches = items.length - montres.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (component.str('title').isNotEmpty)
          ViewportReveal(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                component.str('title'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.35,
                  color: TovoTheme.ink,
                ),
              ),
            ),
          ),
        if (widget.horizontal)
          for (var ligne = 0; ligne < montres.length; ligne += 2)
            Padding(
              padding: EdgeInsets.only(top: ligne == 0 ? 0 : 20),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var colonne = 0; colonne < 2; colonne++) ...[
                      if (colonne == 1) const SizedBox(width: 14),
                      Expanded(
                        child: ligne + colonne < montres.length
                            ? ViewportReveal(
                                delay: Duration(
                                  milliseconds: ligne + colonne < _visibles
                                      ? 200 + (ligne + colonne) * 120
                                      : 0,
                                ),
                                child: ProductTile(
                                  data: montres[ligne + colonne],
                                  onOpen: () => _open(
                                    montres[ligne + colonne],
                                    onInteraction,
                                  ),
                                  onAdd: () => _ajouter(
                                    montres[ligne + colonne],
                                    onInteraction,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            )
        else
          for (final item in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              minVerticalPadding: 16,
              title: Text(
                '${item['name']}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('${item['merchant_name'] ?? ''}'),
              trailing: Text(
                _price(item),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: item['is_available'] == false
                  ? null
                  : () => _open(item, onInteraction),
            ),
        // D'abord le reste de ce qui est déjà là, sans quitter le fil…
        if (widget.horizontal && caches > 0)
          _Suite(
            libelle: caches == 1
                ? 'Voir l’autre produit'
                : 'Voir les $caches autres',
            icone: Icons.expand_more_rounded,
            onPressed: () => setState(() => _tout = true),
          )
        // … puis tout le catalogue correspondant.
        else if (browse.isNotEmpty)
          _Suite(
            libelle:
                'Parcourir les ${browse['total'] ?? items.length} produits',
            icone: Icons.arrow_forward_rounded,
            onPressed: () =>
                onInteraction(TovoInteraction('browse_catalog', browse)),
          ),
      ],
    );
  }
}

class _Suite extends StatelessWidget {
  const _Suite({
    required this.libelle,
    required this.icone,
    required this.onPressed,
  });

  final String libelle;
  final IconData icone;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: SizedBox(
      width: double.infinity,
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFFF4F5F5),
          foregroundColor: TovoTheme.ink,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: onPressed,
        child: Row(
          children: [
            Expanded(
              child: Text(
                libelle,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(icone, size: 18),
          ],
        ),
      ),
    ),
  );
}

String _price(Map<String, dynamic> item) =>
    Money.format((item['price'] as num?)?.toInt() ?? 0);

void _open(Map<String, dynamic> item, InteractionCallback onInteraction) {
  if (item['id'] is String) {
    onInteraction(
      TovoInteraction('select_product', {
        'product_id': item['id'],
        'product': item,
      }),
    );
  }
}

/// « + » : ajouter tout de suite. Un produit à options ouvre sa fiche.
void _ajouter(Map<String, dynamic> item, InteractionCallback onInteraction) {
  if (item['requires_options'] == true) {
    _open(item, onInteraction);
    return;
  }
  if (item['id'] is String) {
    onInteraction(
      TovoInteraction('add_to_cart', {'product_id': item['id'], 'quantity': 1}),
    );
  }
}

/// Hauteur d'une tuile de largeur [largeur] : la photo carrée, puis le
/// texte, qui grandit avec la taille de police choisie par le client.
double hauteurTuileProduit(BuildContext context, double largeur) {
  final echelle = MediaQuery.textScalerOf(context).scale(14) / 14;
  return largeur + 22 + 96 * echelle;
}

/// Un produit en tuile : photo carrée, « + » dessus, nom, boutique, prix.
/// La même dans le fil et dans Explorer.
class ProductTile extends StatelessWidget {
  const ProductTile({
    super.key,
    required this.data,
    required this.onOpen,
    required this.onAdd,
    this.onMerchant,
    this.afficherBoutique = true,
  });
  final Map<String, dynamic> data;
  final VoidCallback onOpen;
  final VoidCallback onAdd;

  /// Rend le nom de la boutique touchable (Explorer, toutes boutiques).
  final VoidCallback? onMerchant;

  /// Faux dans la page d'une boutique : son nom sur chaque tuile ne dirait
  /// rien de plus que l'en-tête.
  final bool afficherBoutique;

  @override
  Widget build(BuildContext context) {
    final available = data['is_available'] != false;
    // Boutique fermée : on peut regarder, pas se faire livrer maintenant.
    final fermee = data['merchant_open'] == false;
    final enRetrait = !available || fermee;
    final photo = data['image_url'] as String?;
    final nom = '${data['name'] ?? ''}';
    const placeholder = ColoredBox(
      color: Color(0xFFF4F5F5),
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 22,
          color: TovoTheme.muted,
        ),
      ),
    );

    return Opacity(
      // Indisponible : visible, pour ne pas faire croire qu'il n'existe pas,
      // mais clairement en retrait.
      opacity: enRetrait ? 0.45 : 1,
      child: Semantics(
        button: true,
        enabled: available,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: available ? onOpen : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: photo == null || photo.isEmpty
                          ? placeholder
                          : CatalogImage(
                              photo,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => placeholder,
                            ),
                    ),
                    if (!enRetrait)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Material(
                          color: Colors.white,
                          shape: const CircleBorder(),
                          elevation: 1,
                          child: IconButton(
                            tooltip: 'Ajouter $nom',
                            onPressed: onAdd,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.add,
                              size: 22,
                              color: TovoTheme.ink,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                nom,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.ink,
                ),
              ),
              const SizedBox(height: 3),
              if (afficherBoutique || !available || fermee)
                _ligneBoutique(available: available, fermee: fermee),
              if (data['requires_options'] == true)
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Text(
                    'À personnaliser',
                    maxLines: 1,
                    style: TextStyle(fontSize: 11, color: TovoTheme.inkDoux),
                  ),
                ),
              const Spacer(),
              const SizedBox(height: 6),
              Text(
                _price(data),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: TovoTheme.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ligneBoutique({required bool available, required bool fermee}) {
    final texte = !available
        ? 'Indisponible pour le moment'
        : fermee
        ? 'Boutique fermée'
        : '${data['merchant_name'] ?? ''}${onMerchant != null ? ' ›' : ''}';
    final ligne = Text(
      texte,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
    );
    if (onMerchant == null || !available || fermee) return ligne;
    return InkWell(
      onTap: onMerchant,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ligne,
      ),
    );
  }
}
