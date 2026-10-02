import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/noms.dart';
import '../../core/catalog_image.dart';
import '../../core/viewport_reveal.dart';
import '../registry.dart';

/// Les produits trouvés, dans le fil.
///
/// Une rangée qui glisse : quatre produits, deux visibles et le troisième qui
/// dépasse — on comprend qu'il faut glisser. La suite : UN seul bouton sous la
/// rangée, « Parcourir les 34 autres produits », qui ouvre l'explorateur. La
/// flèche du titre et la tuile « +34 / Tout parcourir » faisaient la même
/// chose : trois gestes pour une action (retour du fondateur, 02/10).
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
    final total = (browse['total'] as num?)?.toInt() ?? items.length;
    // Avec un catalogue derrière : quatre ici, la suite dans l'explorateur.
    // Sans : tout ce qu'on a, dans la rangée.
    final montres = browse.isNotEmpty && items.length > _visibles
        ? items.take(_visibles).toList()
        : items;
    final reste = total - montres.length;
    // Une suite à parcourir : le nombre sous le titre, et le bouton dessous.
    final toutVoir =
        widget.horizontal && browse.isNotEmpty && total > montres.length;
    final titre = component.str('title');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (titre.isNotEmpty || toutVoir)
          ViewportReveal(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          titre.isEmpty ? 'Résultats' : _majuscule(titre),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.35,
                            color: TovoTheme.ink,
                          ),
                        ),
                        if (toutVoir)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '$total produits',
                              style: const TextStyle(
                                fontSize: 13,
                                color: TovoTheme.inkDoux,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (widget.horizontal) ...[
          LayoutBuilder(
            builder: (context, contraintes) {
              // Deux tuiles et le début d'une troisième : on voit qu'il y a
              // une suite à glisser.
              final largeur = ((contraintes.maxWidth - 14) / 2 * 0.9).clamp(
                120.0,
                260.0,
              );
              return SizedBox(
                height: hauteurTuileProduit(context, largeur),
                // Une rangée simple (quatre tuiles au plus, plus « la
                // suite ») : une liste paresseuse, imbriquée dans celle du
                // fil, faisait disparaître la flèche « Tout voir » de
                // l'accessibilité.
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < montres.length; i++) ...[
                        if (i > 0) const SizedBox(width: 14),
                        SizedBox(
                          width: largeur,
                          child: ViewportReveal(
                            delay: Duration(
                              milliseconds: i < _visibles ? 200 + i * 120 : 0,
                            ),
                            child: ProductTile(
                              data: montres[i],
                              onOpen: () => _open(montres[i], onInteraction),
                              onAdd: () => _ajouter(montres[i], onInteraction),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          if (_vedette(items) case final vedette?)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _LigneVedette(
                produit: vedette,
                onTap: () => _open(vedette, onInteraction),
              ),
            ),
          if (toutVoir)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: OutlinedButton.icon(
                key: const Key('parcourir-produits'),
                onPressed: () =>
                    onInteraction(TovoInteraction('browse_catalog', browse)),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: TovoTheme.ink,
                  side: const BorderSide(color: Color(0xFFDADDDD)),
                  shape: const StadiumBorder(),
                ),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.arrow_forward_rounded, size: 19),
                label: Text(
                  _parcourir(reste),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ] else
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
      ],
    );
  }
}

/// Le produit marqué « le plus commandé » par le serveur (`plus_commande`).
/// Aucun chiffre ne quitte le serveur : on ne montre pas de nombre de
/// commandes (demande du client, 26/09).
Map<String, dynamic>? _vedette(List<Map<String, dynamic>> items) => items
    .where((i) => i['plus_commande'] == true && i['is_available'] != false)
    .firstOrNull;

/// Sous la rangée : « Le plus commandé en ce moment : Royal tacos ».
/// Le client voit ce que les autres choisissent, et y va d'un geste.
class _LigneVedette extends StatelessWidget {
  const _LigneVedette({required this.produit, required this.onTap});

  final Map<String, dynamic> produit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('vedette-produits'),
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Icon(
              Icons.trending_up_rounded,
              size: 18,
              color: TovoTheme.ink,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: 'Le plus commandé en ce moment : ',
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: TovoTheme.inkDoux,
                  ),
                  children: [
                    TextSpan(
                      text: enPhrase('${produit['name'] ?? ''}'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: TovoTheme.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: TovoTheme.inkDoux,
            ),
          ],
        ),
      ),
    );
  }
}

String _parcourir(int reste) => reste == 1
    ? 'Parcourir l’autre produit'
    : 'Parcourir les $reste autres produits';

String _majuscule(String texte) =>
    texte.isEmpty ? texte : texte[0].toUpperCase() + texte.substring(1);

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
double hauteurTuileProduit(
  BuildContext context,
  double largeur, {
  bool avecBoutique = true,
}) {
  final echelle = MediaQuery.textScalerOf(context).scale(14) / 14;
  // Sans la ligne « boutique » (page d'une enseigne), la tuile est plus
  // courte : sinon un grand vide séparait le nom du plat de son prix.
  return largeur + 22 + (avecBoutique ? 96 : 76) * echelle;
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
    // Seul un article INDISPONIBLE passe en retrait. Une boutique fermée,
    // on la parcourt comme les autres — souvent tard le soir, pour choisir
    // pour le lendemain (demande du client, 25/09) : pas de voile blanc, pas
    // de « Boutique fermée » sur chaque tuile. Sa page le dit, une fois.
    final enRetrait = !available;
    final photo = data['image_url'] as String?;
    final nom = enPhrase('${data['name'] ?? ''}');
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
              // Le nom occupe TOUJOURS deux lignes : un nom court à côté
              // d'un long décalait tout ce qui suit (boutique, prix). Une
              // seconde ligne vide et invisible réserve la place, à la
              // taille de police choisie par le client.
              Stack(
                children: [
                  const Opacity(
                    opacity: 0,
                    child: Text('\n', maxLines: 2, style: _styleNom),
                  ),
                  Text(
                    nom,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _styleNom,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              // « À personnaliser » n'est plus écrit : le « + » d'un article à
              // options ouvre sa fiche, qui les montre. Le dire sur la tuile
              // était du bruit.
              if (afficherBoutique || !available)
                _ligneBoutique(available: available),
              // Le prix se cale en bas : aligné d'une tuile à l'autre.
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

  static const _styleNom = TextStyle(
    fontFamily: TovoTheme.policeNoms,
    fontSize: 15,
    height: 1.25,
    fontWeight: FontWeight.w500,
    color: TovoTheme.ink,
  );

  Widget _ligneBoutique({required bool available}) {
    final texte = !available
        ? 'Indisponible pour le moment'
        : '${enPhrase(data['merchant_name'] as String?)}${onMerchant != null ? ' ›' : ''}';
    final ligne = Text(
      texte,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
    );
    if (onMerchant == null || !available) return ligne;
    return InkWell(
      onTap: onMerchant,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ligne,
      ),
    );
  }
}
