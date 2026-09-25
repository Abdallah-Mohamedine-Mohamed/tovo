import 'package:flutter/material.dart';

import '../../components/widgets/pastille_panier.dart';
import '../../components/widgets/product_carousel.dart';
import '../../core/api.dart';
import '../../core/noms.dart';
import '../../core/panier.dart';
import '../../core/theme.dart';
import 'cart_screen.dart';
import 'product_sheet.dart';

/// « Tout voir » : tous les produits d'une boutique, un rayon par page.
///
/// En haut, les rayons, alignés à gauche ; dessous, la page du rayon, deux
/// produits par ligne. Un glissement du doigt vers la gauche ou la droite
/// passe au rayon suivant ou précédent, comme on feuillette (demande du
/// client, 25/09). Rien d'autre : pas de titre répété, pas de compteur.
///
/// La carte est déjà chargée par la page boutique : aucune requête ici.
/// Renvoie la commande passée depuis le panier, comme les autres écrans.
class RayonsScreen extends StatefulWidget {
  const RayonsScreen({
    super.key,
    required this.api,
    required this.rayons,
    this.depart = 0,
    this.conversationId,
  });

  final TovoApi api;

  /// Les rayons de la boutique, chacun avec ses produits (`items`).
  final List<Map<String, dynamic>> rayons;

  /// Le rayon ouvert en premier.
  final int depart;
  final String? conversationId;

  @override
  State<RayonsScreen> createState() => _RayonsScreenState();
}

class _RayonsScreenState extends State<RayonsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _onglets = TabController(
    length: widget.rayons.length,
    initialIndex: widget.depart.clamp(0, widget.rayons.length - 1),
    vsync: this,
  );

  @override
  void dispose() {
    _onglets.dispose();
    super.dispose();
  }

  Future<void> _ouvrirProduit(Map<String, dynamic> produit) async {
    final issue = await showProductSheet(
      context,
      api: widget.api,
      productId: produit['id'] as String,
      initialProduct: produit,
    );
    if (mounted && issue == IssueFiche.commander) await _ouvrirPanier();
  }

  Future<void> _ouvrirPanier() async {
    final commande = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => CartScreen(
          api: widget.api,
          initialCart: PanierEnDirect.instance.value?.composant,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted && commande != null) Navigator.of(context).pop(commande);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: PastillePanier(onTap: _ouvrirPanier),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Material(
                color: const Color(0xFFF4F5F5),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Retour',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: TovoTheme.ink,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            TabBar(
              controller: _onglets,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              labelPadding: const EdgeInsets.symmetric(horizontal: 10),
              labelColor: TovoTheme.ink,
              unselectedLabelColor: TovoTheme.inkDoux,
              labelStyle: const TextStyle(
                fontFamily: TovoTheme.policeClient,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: const TextStyle(
                fontFamily: TovoTheme.policeClient,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              indicatorColor: TovoTheme.ink,
              indicatorWeight: 2,
              indicatorSize: TabBarIndicatorSize.label,
              dividerColor: const Color(0xFFEDEEEE),
              overlayColor: WidgetStateProperty.all(Colors.transparent),
              tabs: [
                for (final rayon in widget.rayons)
                  Tab(height: 44, text: enPhrase('${rayon['name'] ?? ''}')),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _onglets,
                children: [for (final rayon in widget.rayons) _page(rayon)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _page(Map<String, dynamic> rayon) {
    final items = (rayon['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return ListView.builder(
      // Une page par rayon : chacune garde sa position de défilement.
      key: PageStorageKey('rayon-${rayon['id'] ?? rayon['name']}'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 110),
      itemCount: (items.length + 1) ~/ 2,
      itemBuilder: (_, ligne) => Padding(
        padding: EdgeInsets.only(top: ligne == 0 ? 0 : 22),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var colonne = 0; colonne < 2; colonne++) ...[
                if (colonne == 1) const SizedBox(width: 14),
                Expanded(
                  child: ligne * 2 + colonne < items.length
                      ? ProductTile(
                          data: items[ligne * 2 + colonne],
                          afficherBoutique: false,
                          onOpen: () =>
                              _ouvrirProduit(items[ligne * 2 + colonne]),
                          onAdd: () =>
                              _ouvrirProduit(items[ligne * 2 + colonne]),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
