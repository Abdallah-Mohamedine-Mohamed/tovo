import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/widgets/pastille_panier.dart';
import '../../components/widgets/product_carousel.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/noms.dart';
import '../../core/panier.dart';
import '../../core/theme.dart';
import 'cart_screen.dart';
import 'catalog_screen.dart';
import 'product_sheet.dart';

/// Une catégorie d'une boutique en affichage « catégories » (Niger Beauté).
///
/// Deux écrans en tout, pas trois (demande du client, 22/10) : la boutique
/// et ses catégories, puis ici les articles. Les sous-catégories sont des
/// pastilles en haut qui filtrent SUR PLACE — « Tous » d'abord — au lieu
/// d'un écran de plus où elles ressemblaient à des articles. Dessous, le
/// budget et l'ordre, puis les articles deux par ligne, sur fond blanc.
///
/// Tous les articles de la catégorie arrivent en un appel : filtrer et
/// trier ne demandent rien au serveur. Renvoie la commande passée depuis le
/// panier, comme les autres écrans.
class RayonBoutiqueScreen extends StatefulWidget {
  const RayonBoutiqueScreen({
    super.key,
    required this.api,
    required this.merchantId,
    required this.cle,
    required this.nom,
    this.conversationId,
  });

  final TovoApi api;
  final String merchantId;

  /// La clé de la catégorie dans la boutique (« parfums »).
  final String cle;

  /// Son nom, affiché tout de suite sans attendre les articles.
  final String nom;
  final String? conversationId;

  @override
  State<RayonBoutiqueScreen> createState() => _RayonBoutiqueScreenState();
}

/// Les tranches de prix, en francs CFA.
enum Budget {
  tous('Tous les prix', 0, null),
  petit('Moins de 5 000 F', 0, 5000),
  moyen('5 000 à 10 000 F', 5000, 10000),
  grand('Plus de 10 000 F', 10000, null);

  const Budget(this.libelle, this.min, this.max);
  final String libelle;
  final int min;

  /// Exclu ; null : sans plafond.
  final int? max;

  bool accepte(num prix) => prix >= min && (max == null || prix < max!);
}

enum Ordre {
  demandes('Les plus demandés'),
  prixCroissant('Prix croissant'),
  prixDecroissant('Prix décroissant');

  const Ordre(this.libelle);
  final String libelle;
}

class _RayonBoutiqueScreenState extends State<RayonBoutiqueScreen> {
  List<Map<String, dynamic>> _items = [];
  List<String> _pastilles = [];
  String _boutique = '';
  bool _charge = true;
  String? _erreur;

  /// La pastille choisie ; null : « Tous ».
  String? _pastille;
  Budget _budget = Budget.tous;
  Ordre _ordre = Ordre.demandes;

  String get _chemin => '/merchants/${widget.merchantId}/rayons/${widget.cle}';

  @override
  void initState() {
    super.initState();
    unawaited(_charger());
  }

  Future<void> _charger() async {
    final requete = widget.api.get(_chemin);
    final cache = await widget.api.cachedGet(_chemin);
    if (!mounted) return;
    if (cache != null) _appliquer(cache);
    final reponse = await requete;
    if (!mounted) return;
    if (reponse.ok) {
      _appliquer(reponse);
    } else if (_items.isEmpty) {
      setState(() {
        _charge = false;
        _erreur = reponse.content;
      });
    }
  }

  void _appliquer(TovoResponse reponse) {
    setState(() {
      _charge = false;
      _erreur = null;
      _items = reponse.list('items');
      _pastilles = [
        for (final p in (reponse.raw['pastilles'] as List? ?? const []))
          '$p',
      ];
      if (!_pastilles.contains(_pastille)) _pastille = null;
      final fiche = reponse.raw['merchant'];
      if (fiche is Map<String, dynamic>) {
        _boutique = '${fiche['name'] ?? ''}';
      }
    });
  }

  /// Les articles montrés : la pastille, puis le budget, dans l'ordre choisi.
  /// « Les plus demandés » est l'ordre du serveur.
  List<Map<String, dynamic>> get _montres {
    final liste = _items
        .where((p) => _pastille == null || p['sous_rayon'] == _pastille)
        .where((p) => _budget.accepte((p['price'] as num?) ?? 0))
        .toList();
    num prix(Map<String, dynamic> p) => (p['price'] as num?) ?? 0;
    if (_ordre == Ordre.prixCroissant) {
      liste.sort((a, b) => prix(a).compareTo(prix(b)));
    } else if (_ordre == Ordre.prixDecroissant) {
      liste.sort((a, b) => prix(b).compareTo(prix(a)));
    }
    return liste;
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

  Future<void> _rechercher() async {
    final commande = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => CatalogScreen(
          api: widget.api,
          merchantId: widget.merchantId,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted && commande != null) Navigator.of(context).pop(commande);
  }

  @override
  Widget build(BuildContext context) {
    final montres = _montres;
    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: PastillePanier(onTap: _ouvrirPanier),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _charger,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _enTete()),
              if (_pastilles.isNotEmpty)
                SliverToBoxAdapter(child: _rangeeDePastilles()),
              if (_charge && _items.isEmpty)
                const SliverToBoxAdapter(child: ReadPlaceholder())
              else if (_erreur != null && _items.isEmpty)
                SliverToBoxAdapter(child: _echec())
              else ...[
                SliverToBoxAdapter(child: _reglages(montres.length)),
                if (montres.isEmpty)
                  SliverToBoxAdapter(child: _aucun())
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    sliver: SliverList.builder(
                      itemCount: (montres.length + 1) ~/ 2,
                      itemBuilder: (_, ligne) => _ligne(montres, ligne),
                    ),
                  ),
              ],
              // La pastille panier ne cache pas le dernier article.
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boutonRond({
    required IconData icone,
    required String aide,
    required VoidCallback onTap,
  }) => Material(
    color: TovoTheme.bloc,
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: aide,
      onPressed: onTap,
      icon: Icon(icone, size: 21, color: TovoTheme.ink),
    ),
  );

  Widget _enTete() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Row(
      children: [
        _boutonRond(
          icone: Icons.arrow_back_rounded,
          aide: 'Retour',
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.nom,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 24,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: TovoTheme.ink,
                ),
              ),
              if (_boutique.isNotEmpty)
                Text(
                  enPhrase(_boutique),
                  style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _boutonRond(
          icone: Icons.search_rounded,
          aide: 'Rechercher dans la boutique',
          onTap: _rechercher,
        ),
      ],
    ),
  );

  /// « Tous », puis les sous-catégories. La rangée déborde à droite : on
  /// devine qu'elle défile.
  Widget _rangeeDePastilles() => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _pastilles.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _pastilleWidget(i == 0 ? null : _pastilles[i - 1]),
      ),
    ),
  );

  Widget _pastilleWidget(String? valeur) {
    final choisie = valeur == _pastille;
    return Semantics(
      selected: choisie,
      button: true,
      child: Material(
        key: ValueKey('pastille-${valeur ?? 'tous'}'),
        color: choisie ? TovoTheme.ink : TovoTheme.bloc,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => setState(() => _pastille = valeur),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(
                valeur ?? 'Tous',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: choisie ? Colors.white : TovoTheme.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Le nombre d'articles, discret ; puis le budget et l'ordre.
  Widget _reglages(int nombre) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            nombre == 1 ? '1 article' : '$nombre articles',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TovoTheme.inkDoux,
            ),
          ),
        ),
        _menu(
          cle: 'budget',
          libelle: _budget == Budget.tous ? 'Budget' : _budget.libelle,
          onTap: _choisirBudget,
        ),
        const SizedBox(width: 4),
        _menu(cle: 'ordre', libelle: _ordre.libelle, onTap: _choisirOrdre),
      ],
    ),
  );

  Widget _menu({
    required String cle,
    required String libelle,
    required VoidCallback onTap,
  }) => TextButton(
    key: ValueKey('menu-$cle'),
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: TovoTheme.ink,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(
        fontFamily: TovoTheme.policeClient,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(libelle),
        const SizedBox(width: 2),
        const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
      ],
    ),
  );

  Future<T?> _feuille<T>({
    required String titre,
    required List<T> choix,
    required T actuel,
    required String Function(T) libelle,
  }) => showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (feuille) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              titre,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final c in choix)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(feuille, c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          libelle(c),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: c == actuel
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: TovoTheme.ink,
                          ),
                        ),
                      ),
                      if (c == actuel)
                        const Icon(
                          Icons.check_rounded,
                          size: 22,
                          color: TovoTheme.ink,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _choisirBudget() async {
    final choix = await _feuille<Budget>(
      titre: 'Budget',
      choix: Budget.values,
      actuel: _budget,
      libelle: (b) => b.libelle,
    );
    if (mounted && choix != null) setState(() => _budget = choix);
  }

  Future<void> _choisirOrdre() async {
    final choix = await _feuille<Ordre>(
      titre: 'Trier',
      choix: Ordre.values,
      actuel: _ordre,
      libelle: (o) => o.libelle,
    );
    if (mounted && choix != null) setState(() => _ordre = choix);
  }

  Widget _ligne(List<Map<String, dynamic>> items, int ligne) => Padding(
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
                      onOpen: () => _ouvrirProduit(items[ligne * 2 + colonne]),
                      onAdd: () => _ouvrirProduit(items[ligne * 2 + colonne]),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _aucun() => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 0),
    child: Column(
      children: [
        const Text(
          'Aucun article dans ce budget.',
          textAlign: TextAlign.center,
          style: TextStyle(color: TovoTheme.inkDoux),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() => _budget = Budget.tous),
          child: const Text('Voir tous les prix'),
        ),
      ],
    ),
  );

  Widget _echec() => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Text(_erreur ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () {
            setState(() {
              _charge = true;
              _erreur = null;
            });
            unawaited(_charger());
          },
          child: const Text('Réessayer'),
        ),
      ],
    ),
  );
}
