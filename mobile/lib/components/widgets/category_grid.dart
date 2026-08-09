import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/icones_categories.dart';
import '../../core/theme.dart';
import '../registry.dart';

/// `category_grid` — tuiles de catégories.
class CategoryGrid extends StatelessWidget {
  const CategoryGrid({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final items = component.list('items');
    if (items.isEmpty) return const SizedBox.shrink();

    final title = component.str('title');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: TovoTheme.gap),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: TovoTheme.ink,
              ),
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            // Un peu plus haut que large : l'icône respire au-dessus du nom
            // au lieu de le toucher.
            childAspectRatio: 0.86,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final id = item['id'] as String?;

            return _Tuile(
              // Trois sources, dans cet ordre : le dessin embarqué, l'image
              // posée en base, puis l'emoji. Chacune n'existe que pour les
              // cas que la précédente ne couvre pas — les rayons de boutique
              // n'ont pas de slug, et les catégories récentes n'ont pas
              // encore d'illustration.
              asset: IconesCategories.pour(item['slug'] as String?),
              imageUrl: item['image_url'] as String?,
              emoji: item['icon'] as String?,
              nom: (item['name'] as String?) ?? '',
              onTap: id == null
                  ? null
                  // `merchant_id` distingue un RAYON de boutique d'une
                  // catégorie du catalogue. Sans lui, toucher « Boissons »
                  // chez GALAXIE renverrait vers toutes les boissons de
                  // Niamey au lieu des siennes.
                  : () => onInteraction(
                        TovoInteraction('select_category', {
                          'category_id': id,
                          if (item['merchant_id'] != null)
                            'merchant_id': item['merchant_id'],
                        }),
                      ),
            );
          },
        ),
      ],
    );
  }
}

/// Une tuile de catégorie.
///
/// `StatefulWidget` pour une seule raison : le retour au toucher. `InkWell`
/// dessine son ondulation SOUS le fond opaque de la tuile — on appuyait donc
/// sans que rien ne bouge, et sur un réseau lent on appuyait deux fois. Ici
/// la tuile s'enfonce et s'assombrit, ce qui se voit toujours.
class _Tuile extends StatefulWidget {
  const _Tuile({
    required this.asset,
    required this.imageUrl,
    required this.emoji,
    required this.nom,
    required this.onTap,
  });

  /// Dessin embarqué dans l'application. Prioritaire : il s'affiche avant
  /// le réseau, ce qui compte pour la première grille que voit le client.
  final String? asset;

  /// Illustration posée en base, pour ce que l'app n'embarque pas.
  final String? imageUrl;

  /// Dernier repli, hérité des catégories d'origine.
  final String? emoji;

  final String nom;
  final VoidCallback? onTap;

  @override
  State<_Tuile> createState() => _TuileState();
}

class _TuileState extends State<_Tuile> {
  bool _presse = false;

  void _majPression(bool valeur) {
    if (widget.onTap == null || _presse == valeur) return;
    setState(() => _presse = valeur);
  }

  /// Le disque coloré fait partie du fichier SVG, pas du widget.
  ///
  /// Une icône, une teinte : le rond reprend la couleur du sujet, ce qui
  /// permet de retrouver « Restaurants » sans lire son nom. Le dessiner ici
  /// obligerait à transporter une couleur par catégorie depuis le serveur,
  /// pour un résultat identique.
  Widget _dessin() {
    final asset = widget.asset;
    if (asset != null) {
      return SvgPicture.asset(asset, width: 44, height: 44);
    }

    final url = widget.imageUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          // Une image absente ne doit pas laisser un trou : le repli gris
          // garde la grille alignée, ce qu'une icône cassée ne ferait pas.
          errorBuilder: (_, __, ___) => _pastilleEmoji(),
        ),
      );
    }

    return _pastilleEmoji();
  }

  Widget _pastilleEmoji() {
    return Container(
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: (widget.emoji ?? '').isEmpty
          ? SvgPicture.asset(IconesCategories.generique, width: 44, height: 44)
          : Text(widget.emoji!, style: const TextStyle(fontSize: 22)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _majPression(true),
      onTapUp: (_) => _majPression(false),
      onTapCancel: () => _majPression(false),
      child: AnimatedScale(
        scale: _presse ? 0.96 : 1,
        duration: TovoTheme.vif,
        curve: TovoTheme.courbe,
        child: AnimatedContainer(
          duration: TovoTheme.vif,
          decoration: BoxDecoration(
            // Un fond doux, pas de bordure. Le trait gris cernait chaque
            // tuile et donnait à la grille un air de tableau de bord.
            color: _presse ? TovoTheme.blocPresse : TovoTheme.bloc,
            borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 44, height: 44, child: _dessin()),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.nom,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: TovoTheme.ink,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
