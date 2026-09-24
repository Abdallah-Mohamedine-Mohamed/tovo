import 'package:flutter/material.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/noms.dart';
import '../../core/theme.dart';
import '../../core/catalog_image.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/panier.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({
    super.key,
    required this.api,
    required this.productId,
    this.initialProduct = const {},
    this.embedded = false,
    this.onClose,
    this.onAdded,
    this.onOrder,
  });

  final TovoApi api;
  final String productId;
  final Map<String, dynamic> initialProduct;
  final bool embedded;
  final VoidCallback? onClose;
  final VoidCallback? onAdded;

  /// « Commander » : l'article est ajouté, puis la commande s'ouvre.
  /// Sans lui, seul « Ajouter au panier » est proposé.
  final VoidCallback? onOrder;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  TovoComponent? _component;
  final Map<String, Set<String>> _choices = {};
  int _quantity = 1;
  bool _loading = true;
  bool _adding = false;
  bool _commande = false;
  String? _error;

  bool get _hasOptions => _component?.type == 'option_selector';
  List<Map<String, dynamic>> get _options => _component?.list('options') ?? [];
  Map<String, dynamic> get _product => {
    ...widget.initialProduct,
    if (!_hasOptions) ...?_component?.data,
    if (_hasOptions) ...{
      'name': _component!.str('product_name'),
      'price': _component!.money('base_price'),
    },
  };

  int get _unitPrice {
    var price = (_product['price'] as num?)?.toInt() ?? 0;
    for (final option in _options) {
      for (final value in (option['values'] as List? ?? []).whereType<Map>()) {
        if (_choices[option['id']]?.contains(value['id']) ?? false) {
          price += (value['price_delta'] as num?)?.toInt() ?? 0;
        }
      }
    }
    return price;
  }

  int _minimum(Map<String, dynamic> option) => option['required'] == true
      ? ((option['min_select'] as num?)?.toInt() ?? 1).clamp(1, 99)
      : 0;

  bool get _complete => _options.every((option) {
    final count = _choices[option['id']]?.length ?? 0;
    return count >= _minimum(option) &&
        count <= ((option['max_select'] as num?)?.toInt() ?? 1);
  });

  bool get _available =>
      _product['is_available'] != false &&
      (_hasOptions ||
          (_component?.data['actions'] as List? ?? const ['add_to_cart'])
              .contains('add_to_cart'));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final response = await widget.api.get('/products/${widget.productId}');
    if (!mounted) return;
    setState(() {
      _loading = false;
      final supported = response.components.where(
        (component) =>
            const ['product_card', 'option_selector'].contains(component.type),
      );
      if (!response.ok || supported.isEmpty) {
        _error = response.ok
            ? 'Ce produit n’est pas disponible pour le moment.'
            : response.content;
        return;
      }
      _component = supported.first;
      _quantity = _component!.money('quantity', 1).clamp(1, 50);
    });
  }

  void _choose(Map<String, dynamic> option, Map<String, dynamic> value) {
    if (_adding || value['available'] == false) return;
    final id = value['id'] as String;
    final choices = _choices.putIfAbsent(option['id'] as String, () => {});
    final maximum = (option['max_select'] as num?)?.toInt() ?? 1;
    setState(() {
      if (choices.contains(id)) {
        choices.remove(id);
      } else if (maximum == 1) {
        choices
          ..clear()
          ..add(id);
      } else if (choices.length < maximum) {
        choices.add(id);
      }
    });
  }

  Future<void> _add({bool commander = false}) async {
    if (_adding || !_complete || !_available || _component == null) return;
    setState(() {
      _adding = true;
      _commande = commander;
      _error = null;
    });
    final body = {
      'product_id': widget.productId,
      'quantity': _quantity,
      'selections': [
        for (final choice in _choices.entries)
          if (choice.value.isNotEmpty)
            {'option_id': choice.key, 'value_ids': choice.value.toList()},
      ],
    };
    var response = await widget.api.post('/cart/items', body);
    if (!mounted) return;
    if (response.statusCode == 409) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Changer de boutique ?'),
          content: Text(response.content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Garder mon panier'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Remplacer le panier'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (replace != true) {
        setState(() => _adding = false);
        return;
      }
      final cleared = await widget.api.delete('/cart');
      if (!mounted) return;
      response = cleared.ok
          ? await widget.api.post('/cart/items', body)
          : cleared;
    }
    if (!mounted) return;
    setState(() => _adding = false);
    if (response.ok) {
      if (commander && widget.onOrder != null) {
        widget.onOrder!.call();
      } else if (widget.embedded) {
        widget.onAdded?.call();
      } else {
        Navigator.pop(context, true);
      }
    } else {
      setState(() => _error = response.content);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    final photo = product['image_url'] as String? ?? '';
    final name = enPhrase(product['name'] as String?);
    final description = product['description'] as String? ?? '';
    final body = _loading && product.isEmpty
        ? widget.embedded
              ? const SizedBox(height: 260, child: ReadPlaceholder())
              : const ReadPlaceholder()
        : _component == null && product.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error ?? 'Le produit n’a pas pu être chargé.'),
                  TextButton(onPressed: _load, child: const Text('Réessayer')),
                ],
              ),
            ),
          )
        : ListView(
            shrinkWrap: widget.embedded,
            physics: widget.embedded
                ? const NeverScrollableScrollPhysics()
                : null,
            padding: EdgeInsets.fromLTRB(20, 8, 20, widget.embedded ? 32 : 108),
            children: [
              if (!widget.embedded && photo.isEmpty) const SizedBox(height: 56),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Vérification du prix et des options…',
                    style: TextStyle(fontSize: 12, color: TovoTheme.muted),
                  ),
                ),
              if (!_loading && _component == null) ...[
                Text(_error ?? 'Produit indisponible.'),
                TextButton(onPressed: _load, child: const Text('Réessayer')),
              ],
              if (widget.embedded) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (photo.isNotEmpty) ...[
                      // Petite dans le panneau, mais on doit pouvoir la voir
                      // en grand : c'est souvent elle qui décide l'achat.
                      Semantics(
                        button: true,
                        label: 'Agrandir la photo',
                        child: InkWell(
                          onTap: () => _showPhoto(photo),
                          borderRadius: BorderRadius.circular(14),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: CatalogImage(
                              photo,
                              width: 86,
                              height: 86,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              fontFamily: TovoTheme.policeNoms,
                              fontSize: 21,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if ((product['merchant_name'] as String?)
                                  ?.isNotEmpty ==
                              true)
                            Text(
                              product['merchant_name'] as String,
                              style: const TextStyle(
                                fontSize: 12,
                                color: TovoTheme.inkDoux,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            Money.format(_unitPrice * _quantity),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ] else ...[
                if (photo.isNotEmpty) ...[
                  Semantics(
                    button: true,
                    label: 'Agrandir la photo',
                    child: InkWell(
                      onTap: () => _showPhoto(photo),
                      borderRadius: BorderRadius.circular(24),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: CatalogImage(
                          photo,
                          height: (MediaQuery.sizeOf(context).width - 40).clamp(
                            180,
                            widget.embedded ? 240 : 420,
                          ),
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: TovoTheme.policeNoms,
                    fontSize: 28,
                    height: 1.12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((product['merchant_name'] as String?)?.isNotEmpty ==
                    true) ...[
                  const SizedBox(height: 6),
                  Text(
                    product['merchant_name'] as String,
                    style: const TextStyle(
                      fontSize: 13,
                      color: TovoTheme.inkDoux,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  Money.format(_unitPrice * _quantity),
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (description.isNotEmpty &&
                  description.trim().toLowerCase() !=
                      name.trim().toLowerCase()) ...[
                const SizedBox(height: 14),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: TovoTheme.inkDoux,
                  ),
                ),
              ],
              if (_options.isNotEmpty) ...[
                const SizedBox(height: 28),
                for (final option in _options) _optionGroup(option),
              ],
              if (_component != null) _quantityControl(),
            ],
          );
    if (widget.embedded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Fermer la fiche',
                  onPressed: _adding ? null : widget.onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
                Expanded(
                  child: Text(
                    product['merchant_name'] as String? ?? 'Le produit',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          body,
          if (_component != null) _footer(),
        ],
      );
    }
    return PopScope(
      canPop: !_adding,
      child: Scaffold(
        backgroundColor: Colors.white,
        floatingActionButton: _component == null ? null : _footer(),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        body: SafeArea(
          child: Stack(
            children: [
              body,
              Positioned(
                top: 12,
                left: 20,
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  elevation: 1,
                  child: IconButton(
                    tooltip: 'Retour à la carte',
                    onPressed: _adding ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPhoto(String url) => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: CatalogImage(
                  url,
                  fit: BoxFit.contain,
                  decodeWidth: 1600,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 12,
              child: IconButton.filledTonal(
                tooltip: 'Fermer la photo',
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _optionGroup(Map<String, dynamic> option) {
    final minimum = _minimum(option);
    final maximum = (option['max_select'] as num?)?.toInt() ?? 1;
    final selected = _choices[option['id']] ?? {};
    final values = (option['values'] as List? ?? [])
        .whereType<Map<String, dynamic>>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${option['name']}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '${minimum > 0 ? 'Obligatoire' : 'Facultatif'} · ${minimum == maximum
                ? '$maximum choix'
                : minimum > 0
                ? '$minimum à $maximum choix'
                : 'jusqu’à $maximum choix'}',
            style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
          ),
          const SizedBox(height: 10),
          for (final value in values)
            Builder(
              builder: (context) {
                final chosen = selected.contains(value['id']);
                final available = value['available'] != false;
                final enabled =
                    available &&
                    !_adding &&
                    (chosen || maximum == 1 || selected.length < maximum);
                final delta = (value['price_delta'] as num?)?.toInt() ?? 0;
                return Semantics(
                  button: true,
                  selected: chosen,
                  enabled: enabled,
                  child: Material(
                    color: chosen ? TovoTheme.tealMist : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: enabled ? () => _choose(option, value) : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 16,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              chosen
                                  ? Icons.check_circle_rounded
                                  : maximum == 1
                                  ? Icons.radio_button_unchecked_rounded
                                  : Icons.check_box_outline_blank_rounded,
                              size: 22,
                              color: chosen
                                  ? TovoTheme.teal
                                  : TovoTheme.inkDoux,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '${value['name']}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: chosen
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: enabled
                                      ? TovoTheme.ink
                                      : TovoTheme.inkDoux,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              !available
                                  ? 'Épuisé'
                                  : delta == 0
                                  ? 'Inclus'
                                  : '${delta > 0 ? '+' : '−'}${Money.format(delta.abs())}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: TovoTheme.inkDoux,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _quantityControl() => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Quantité',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
        IconButton(
          tooltip: 'Diminuer la quantité',
          onPressed: !_adding && _quantity > 1
              ? () => setState(() => _quantity--)
              : null,
          icon: const Icon(Icons.remove_rounded, size: 20),
        ),
        Semantics(
          liveRegion: true,
          label: 'Quantité $_quantity',
          child: SizedBox(
            width: 32,
            child: Text(
              '$_quantity',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Augmenter la quantité',
          onPressed: !_adding && _quantity < 50
              ? () => setState(() => _quantity++)
              : null,
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
      ],
    ),
  );

  Widget _footer() => Padding(
    padding: EdgeInsets.fromLTRB(20, 8, 20, widget.embedded ? 16 : 0),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_error != null)
          Text(_error!, style: const TextStyle(color: TovoTheme.danger)),
        if (!_complete)
          const Text(
            'Choisissez les options obligatoires.',
            style: TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
          ),
        const SizedBox(height: 8),
        // « Commander » n'apparaît que panier vide : la commande est alors
        // exactement cet article, à ce prix. Avec un panier déjà commencé,
        // « Commander · 4 000 F » mentirait sur le total : on ajoute, et la
        // pastille mène à la commande.
        if (widget.onOrder == null ||
            !_available ||
            PanierEnDirect.instance.value != null)
          _bouton(
            principal: true,
            enCours: _adding,
            icone: Icons.add_rounded,
            texte: _available ? 'Ajouter au panier' : 'Indisponible',
            onPressed: () => _add(),
          )
        else
          // Un seul article suffit souvent : « Commander » l'ajoute et ouvre
          // la commande, sans détour par le panier. « Ajouter » reste là
          // pour qui veut composer un panier.
          Row(
            children: [
              _bouton(
                principal: false,
                enCours: _adding && !_commande,
                icone: Icons.add_rounded,
                texte: 'Ajouter',
                onPressed: () => _add(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _bouton(
                  principal: true,
                  enCours: _adding && _commande,
                  texte: 'Commander · ${Money.format(_unitPrice * _quantity)}',
                  onPressed: () => _add(commander: true),
                ),
              ),
            ],
          ),
      ],
    ),
  );

  Widget _bouton({
    required bool principal,
    required bool enCours,
    required String texte,
    required VoidCallback onPressed,
    IconData? icone,
  }) {
    final actif = !_adding && _complete && _available;
    final contenu = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (enCours)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: principal ? Colors.white : TovoTheme.teal,
            ),
          )
        else if (icone != null)
          Icon(icone, size: 20),
        if (enCours || icone != null) const SizedBox(width: 8),
        Flexible(
          child: Text(texte, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
    const forme = StadiumBorder();
    const taille = Size(0, 46);
    const marge = EdgeInsets.symmetric(horizontal: 20);
    return principal
        ? FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TovoTheme.teal,
              foregroundColor: Colors.white,
              minimumSize: taille,
              padding: marge,
              shape: forme,
            ),
            onPressed: actif ? onPressed : null,
            child: contenu,
          )
        : OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: TovoTheme.teal,
              minimumSize: taille,
              padding: marge,
              shape: forme,
            ),
            onPressed: actif ? onPressed : null,
            child: contenu,
          );
  }
}
