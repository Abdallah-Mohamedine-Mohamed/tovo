import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import '../../core/catalog_image.dart';
import '../../components/widgets/pastille_panier.dart';
import '../../components/widgets/product_carousel.dart';
import '../../core/panier.dart';
import '../../components/widgets/read_placeholder.dart';
import 'product_sheet.dart';
import 'boutique_screen.dart';
import 'cart_screen.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.api,
    this.merchantId,
    this.merchantIds = const [],
    this.categoryId,
    this.query = '',
    this.directory = false,
    this.conversationId,
  });

  final TovoApi api;
  final String? merchantId;
  final List<String> merchantIds;
  final String? categoryId;
  final String query;
  final bool directory;

  /// La conversation d'où vient le client, pour y inscrire la commande.
  final String? conversationId;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _scroll = ScrollController();
  late final TextEditingController _search;
  Timer? _debounce;
  final _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _categories = [];
  List<TovoComponent> _merchants = [];
  Map<String, dynamic> _merchant = {};
  String? _category;
  String? _error;
  int? _next;
  int _total = 0;
  int _generation = 0;
  TovoComponent? _cartPreview;
  bool _loading = true;
  bool _directory = false;
  bool _similar = false;
  bool _retryReset = false;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: widget.query);
    _category = widget.categoryId;
    _scroll.addListener(_onScroll);
    unawaited(_start());
    unawaited(_loadCart());
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (widget.directory) {
      // Sans catégorie (carte « Explorer les boutiques » de l'accueil) :
      // TOUTES les boutiques. Ce mode exigeait une catégorie et, sans elle,
      // retombait sur les produits.
      final path = widget.categoryId != null
          ? '/categories/${widget.categoryId}/merchants'
          : '/merchants';
      final request = widget.api.get(path);
      final cached = await widget.api.cachedGet(path);
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _merchants = cached.components
              .where((component) => component.type == 'merchant_card')
              .toList();
          _directory = _merchants.isNotEmpty;
          _loading = false;
        });
      }
      final response = await request;
      if (!mounted) return;
      if (!response.ok) {
        setState(() {
          _error = response.content;
          _loading = false;
        });
        return;
      }
      final merchants = response.components
          .where((component) => component.type == 'merchant_card')
          .toList();
      if (merchants.isNotEmpty) {
        setState(() {
          _merchants = merchants;
          _directory = true;
          _loading = false;
        });
        return;
      }
    }
    await _load(reset: true);
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 400 &&
        !_loading &&
        _error == null &&
        _next != null) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || _next == null)) return;
    final generation = reset ? ++_generation : _generation;
    final offset = reset ? 0 : _next!;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _next = null;
      }
    });
    final query = <String, dynamic>{
      'q': _search.text.trim(),
      'offset': offset,
      'limit': 24,
      if (widget.merchantId != null) 'merchant_id': widget.merchantId,
      if (widget.merchantIds.isNotEmpty)
        'merchant_ids': widget.merchantIds.join(','),
      if (_category != null) 'category_id': _category,
    };
    final request = widget.api.get('/catalog/products', query: query);
    if (reset) {
      final cached = await widget.api.cachedGet(
        '/catalog/products',
        query: query,
      );
      if (!mounted || generation != _generation) return;
      if (cached != null) {
        setState(() {
          _items.addAll(cached.list('items'));
          _total = (cached.raw['total'] as num?)?.toInt() ?? _items.length;
          _categories = cached.list('categories');
          if (cached.raw['merchant'] is Map<String, dynamic>) {
            _merchant = cached.raw['merchant'] as Map<String, dynamic>;
          }
        });
      }
    }
    final response = await request;
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      if (!response.ok) {
        _retryReset = reset;
        _error = response.content;
        return;
      }
      if (reset) _items.clear();
      final known = _items.map((item) => item['id']).toSet();
      _items.addAll(
        response.list('items').where((item) => known.add(item['id'])),
      );
      _total = (response.raw['total'] as num?)?.toInt() ?? _items.length;
      _next = (response.raw['next_offset'] as num?)?.toInt();
      _similar = response.raw['match_type'] == 'similar';
      _categories = response.list('categories');
      final merchant = response.raw['merchant'];
      if (merchant is Map<String, dynamic>) _merchant = merchant;
    });
  }

  void _queryChanged(String value) {
    _debounce?.cancel();
    if (_directory) {
      setState(() {});
      return;
    }
    _generation++;
    setState(() {
      _loading = true;
      _next = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _load(reset: true),
    );
  }

  Future<void> _loadCart() async {
    final response = await widget.api.get('/cart');
    if (!mounted || !response.ok) return;
    final component = response.components
        .where((component) => component.type == 'cart_summary')
        .firstOrNull;
    setState(() {
      _cartPreview = component;
    });
  }

  Future<void> _openMerchant(
    String id, [
    Map<String, dynamic> apercu = const {},
  ]) async {
    final order = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => BoutiqueScreen(
          api: widget.api,
          merchantId: id,
          apercu: apercu,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (!mounted) return;
    if (order != null) {
      Navigator.of(context).pop(order);
    } else {
      await _loadCart();
    }
  }

  Future<void> _openProduct(String id) async {
    final matching = _items.where((item) => item['id'] == id);
    final issue = await showProductSheet(
      context,
      api: widget.api,
      productId: id,
      initialProduct: matching.isEmpty ? const {} : matching.first,
    );
    if (!mounted) return;
    if (issue == IssueFiche.commander) {
      await _openCart();
    } else {
      await _loadCart();
    }
  }

  Widget _tuile(Map<String, dynamic> produit) {
    void ouvrir() => _openProduct(produit['id'] as String);
    return ProductTile(
      data: produit,
      onOpen: ouvrir,
      onAdd: ouvrir,
      afficherBoutique: widget.merchantId == null,
      onMerchant: widget.merchantId == null
          ? () => _openMerchant(produit['merchant_id'] as String)
          : null,
    );
  }

  Future<void> _openCart() async {
    final order = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => CartScreen(
          api: widget.api,
          initialCart: PanierEnDirect.instance.value?.composant ?? _cartPreview,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (!mounted) return;
    if (order != null) {
      Navigator.of(context).pop(order);
    } else {
      await _loadCart();
    }
  }

  void _interaction(TovoInteraction interaction) {
    if (interaction.action == 'select_merchant') {
      unawaited(
        _openMerchant(
          interaction.payload['merchant_id'] as String,
          (interaction.payload['apercu'] as Map?)?.cast<String, dynamic>() ??
              const {},
        ),
      );
    }
  }

  void _selectCategory(String? category) {
    _debounce?.cancel();
    _category = category;
    unawaited(_load(reset: true));
  }

  Future<void> _showCategories() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Text(
                  'Les catégories',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      title: const Text('Toute la carte'),
                      trailing: _category == null
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _selectCategory(null);
                      },
                    ),
                    for (final category in _categories)
                      ListTile(
                        title: Text('${category['name']}'),
                        subtitle: Text('${category['produits']} produits'),
                        trailing: _category == category['id']
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _selectCategory(category['id'] as String);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
    child: TextField(
      controller: _search,
      onChanged: _queryChanged,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) {
        _debounce?.cancel();
        if (!_directory) unawaited(_load(reset: true));
      },
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded, size: 21),
        hintText: _directory
            ? 'Chercher une enseigne'
            : widget.merchantId != null
            ? 'Rechercher dans la carte'
            : 'Rechercher un produit',
        hintStyle: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
        filled: true,
        fillColor: const Color(0xFFF4F5F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _search,
          builder: (_, value, child) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Effacer la recherche',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    _search.clear();
                    _queryChanged('');
                  },
                ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final merchantName = _merchant['name'] as String?;
    final visibleMerchants = _merchants
        .where(
          (merchant) => merchant
              .str('name')
              .toLowerCase()
              .contains(_search.text.toLowerCase()),
        )
        .toList();
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        centerTitle: true,
        title: Text(widget.merchantId != null ? 'La carte' : 'Explorer'),
        leading: IconButton(
          tooltip: 'Retour',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      // La même pastille que dans la discussion : le panier au même endroit,
      // partout, et à jour dès le premier ajout.
      floatingActionButton: PastillePanier(onTap: _openCart),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: RefreshIndicator(
        onRefresh: () => _directory ? _start() : _load(reset: true),
        child: CustomScrollView(
          cacheExtent: 700,
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            // Venu de « Tout voir » : le titre est la
                            // recherche elle-même (« Poulet »), comme un
                            // rayon, pas un « Trouvez votre envie. » générique
                            // qui faisait croire à un catalogue sans rapport.
                            merchantName ??
                                (_directory
                                    ? 'Les bonnes adresses.'
                                    : widget.query.trim().isNotEmpty &&
                                          _search.text.trim() ==
                                              widget.query.trim()
                                    ? _majuscule(widget.query.trim())
                                    : 'Trouvez votre envie.'),
                            style: const TextStyle(
                              fontSize: 30,
                              height: 1.1,
                              letterSpacing: -0.9,
                              fontWeight: FontWeight.w700,
                              color: TovoTheme.ink,
                            ),
                          ),
                        ),
                        if (_merchant['logo_url'] is String) ...[
                          const SizedBox(width: 20),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: CatalogImage(
                              _merchant['logo_url'] as String,
                              width: 58,
                              height: 58,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_merchant.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _merchant['is_open'] == true
                                  ? TovoTheme.success
                                  : TovoTheme.inkDoux,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            _merchant['is_open'] == true
                                ? 'Ouverte'
                                : 'Fermée pour le moment',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: TovoTheme.inkDoux,
                            ),
                          ),
                        ],
                      ),
                      if ((_merchant['address_hint'] as String? ?? '')
                          .isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          _merchant['address_hint'] as String,
                          style: const TextStyle(
                            fontSize: 12,
                            color: TovoTheme.inkDoux,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _CatalogueBar(
                height:
                    80 +
                    (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(
                      0,
                      40,
                    ),
                child: _searchField(),
              ),
            ),
            if (_categories.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _SectionTab(
                                label: 'Toute la carte',
                                selected: _category == null,
                                onTap: () => _selectCategory(null),
                              ),
                              for (final category in _categories)
                                _SectionTab(
                                  label:
                                      '${category['name']} · ${category['produits']}',
                                  selected: _category == category['id'],
                                  onTap: () =>
                                      _selectCategory(category['id'] as String),
                                ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Toutes les catégories',
                        onPressed: _showCategories,
                        icon: const Icon(Icons.tune_rounded, size: 21),
                      ),
                    ],
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: Text(
                  _directory
                      ? '${visibleMerchants.length} enseignes'
                      : _loading && _items.isEmpty
                      ? 'Chargement…'
                      : '$_total ${_similar ? 'suggestions' : 'produits'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TovoTheme.inkDoux,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            if (_directory)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList.builder(
                  itemCount: visibleMerchants.length,
                  itemBuilder: (_, index) => ComponentRegistry.build(
                    visibleMerchants[index],
                    _interaction,
                  ),
                ),
              )
            else
              // La même grille que dans le fil : deux colonnes, photo
              // d'abord. Le « + » ouvre la fiche, qui gère les options et
              // l'ajout au panier d'Explorer.
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                // Des rangées de deux, chacune à la hauteur de son contenu :
                // une grille à hauteur fixe réservait à toutes les tuiles la
                // place du pire cas, et laissait des vides sous les prix.
                sliver: SliverList.builder(
                  itemCount: (_items.length + 1) ~/ 2,
                  itemBuilder: (_, rangee) => Padding(
                    padding: EdgeInsets.only(top: rangee == 0 ? 0 : 22),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var colonne = 0; colonne < 2; colonne++) ...[
                            if (colonne == 1) const SizedBox(width: 14),
                            Expanded(
                              child: rangee * 2 + colonne < _items.length
                                  ? _tuile(_items[rangee * 2 + colonne])
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () =>
                            _items.isEmpty || _retryReset ? _start() : _load(),
                        child: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loading)
              SliverToBoxAdapter(
                child: _items.isEmpty && _merchants.isEmpty
                    ? const ReadPlaceholder()
                    : const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Actualisation…',
                          style: TextStyle(
                            fontSize: 12,
                            color: TovoTheme.muted,
                          ),
                        ),
                      ),
              ),
            if (!_loading && _error == null && _items.isEmpty && !_directory)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _search.text.isEmpty
                        ? 'Aucun produit disponible dans cette catégorie.'
                        : 'Aucun résultat. Essayez un autre nom ou une autre catégorie.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            if (!_loading && _next != null && _error == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextButton(
                    onPressed: _load,
                    child: Text(
                      'Afficher la suite · ${_items.length} sur $_total',
                    ),
                  ),
                ),
              ),
            // De la place sous le dernier produit : la pastille ne le cache pas.
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}

class _CatalogueBar extends SliverPersistentHeaderDelegate {
  _CatalogueBar({required this.child, required this.height});
  final Widget child;
  final double height;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox.expand(
    child: ColoredBox(color: Colors.white, child: child),
  );
  @override
  bool shouldRebuild(covariant _CatalogueBar oldDelegate) =>
      oldDelegate.child != child || oldDelegate.height != height;
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? TovoTheme.ink : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? TovoTheme.ink : TovoTheme.inkDoux,
          ),
        ),
      ),
    ),
  );
}

String _majuscule(String texte) =>
    texte.isEmpty ? texte : texte[0].toUpperCase() + texte.substring(1);
