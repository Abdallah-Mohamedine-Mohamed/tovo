import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../../core/catalog_image.dart';

class _DeliveryPoint {
  const _DeliveryPoint(this.hint, this.lat, this.lng);
  final String hint;
  final double lat;
  final double lng;
}

class CartScreen extends StatefulWidget {
  const CartScreen({
    super.key,
    required this.api,
    this.initialAddressId,
    this.initialCart,
    this.conversationId,
  });
  final TovoApi api;
  final String? initialAddressId;
  final TovoComponent? initialCart;

  /// La conversation d'où vient le client : la commande y est inscrite,
  /// et son suivi y sera encore quand il la rouvrira.
  final String? conversationId;

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  TovoComponent? _cart;
  bool _busy = true;
  String? _error;
  int _step = 0;
  List<Map<String, dynamic>> _addresses = const [];
  bool _addressesLoading = true;
  String? _addressId;
  _DeliveryPoint? _currentPoint;
  final _hint = TextEditingController();
  final _scroll = ScrollController();
  final _quoteKey = GlobalKey();
  String _payment = 'cash';
  String? _orderId;

  @override
  void dispose() {
    _hint.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _DeliveryPoint? get _destination {
    if (_addressId != null) {
      for (final address in _addresses) {
        if (address['id'] == _addressId &&
            address['lat'] is num &&
            address['lng'] is num) {
          return _DeliveryPoint(
            '${address['text_hint'] ?? ''}',
            (address['lat'] as num).toDouble(),
            (address['lng'] as num).toDouble(),
          );
        }
      }
    }
    // Position GPS prise : elle suffit. Le repère aide le livreur mais ne
    // doit pas bloquer la commande — il appelle le client si besoin. Exiger
    // le repère laissait le client devant une erreur et un bouton grisé.
    if (_currentPoint != null) {
      final repere = _hint.text.trim();
      return _DeliveryPoint(
        repere.isEmpty ? 'Position du client (le livreur appellera)' : repere,
        _currentPoint!.lat,
        _currentPoint!.lng,
      );
    }
    return null;
  }

  Future<void> _loadAddresses() async {
    final response = await widget.api.get('/addresses');
    if (!mounted) return;
    setState(() {
      _addressesLoading = false;
      _addresses = response.ok
          ? response
                .list('addresses')
                .where(
                  (address) => address['lat'] is num && address['lng'] is num,
                )
                .toList()
          : const [];
      if (_currentPoint == null && _addressId == null) {
        _addressId =
            _addresses
                    .where(
                      (address) => address['id'] == widget.initialAddressId,
                    )
                    .firstOrNull?['id']
                as String?;
        _addressId ??=
            _addresses
                    .where((address) => address['is_default'] == true)
                    .firstOrNull?['id']
                as String?;
        _addressId ??= _addresses.firstOrNull?['id'] as String?;
      }
    });
  }

  Future<void> _useLocation() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Déjà connue depuis l'ouverture de l'app : aucune attente GPS.
    final position =
        TovoLocation.recente ??
        await TovoLocation.current(requestPermission: true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (position == null) {
        _error =
            'Activez la localisation pour livrer à votre position, ou choisissez une adresse enregistrée.';
      } else {
        _addressId = null;
        _currentPoint = _DeliveryPoint(
          '',
          position.latitude,
          position.longitude,
        );
        _step = 0;
      }
    });
  }

  Future<void> _review() async {
    final destination = _destination;
    if (destination == null) {
      setState(
        () => _error =
            'Choisissez une adresse ou indiquez un repère de livraison.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final response = await widget.api.get(
      '/cart',
      query: {'lat': destination.lat, 'lng': destination.lng},
    );
    if (!mounted) return;
    final carts = response.components.where(
      (component) => component.type == 'cart_summary',
    );
    final cart = carts.firstOrNull;
    setState(() {
      _busy = false;
      if (!response.ok || cart == null || !cart.flag('can_checkout')) {
        _error = response.ok
            ? cart?.str(
                    'blocked_reason',
                    'Votre panier ne peut pas être commandé.',
                  ) ??
                  'Votre panier ne peut pas être commandé.'
            : response.content;
        return;
      }
      _cart = cart;
      _step = 2;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final quoteContext = _quoteKey.currentContext;
      if (quoteContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            quoteContext,
            duration: const Duration(milliseconds: 300),
            alignment: 0.2,
          ),
        );
      } else if (_scroll.hasClients) {
        unawaited(
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  Future<void> _placeOrder() async {
    final destination = _destination;
    if (_busy || destination == null) return;
    _orderId ??= _newOrderId();
    setState(() {
      _busy = true;
      _error = null;
    });
    final response = await widget.api.post('/orders', {
      'type': 'delivery',
      'client_order_id': _orderId,
      'dropoff_hint': destination.hint,
      'dropoff': {'lat': destination.lat, 'lng': destination.lng},
      'payment_method': _payment,
      if (widget.conversationId != null)
        'conversation_id': widget.conversationId,
    });
    if (!mounted) return;
    if (response.ok) {
      unawaited(HapticFeedback.mediumImpact());
      unawaited(TovoPush.enregistrer('client'));
      Navigator.of(context).pop(response);
      return;
    }
    setState(() {
      _busy = false;
      _error = response.content;
    });
  }

  /// Une étiquette qui dit quelque chose (« Maison », « Bureau »), pas
  /// l'étiquette par défaut.
  static bool _etiquetteParlante(Object? label) {
    final texte = '${label ?? ''}'.trim().toLowerCase();
    return texte.isNotEmpty && texte != 'adresse';
  }

  static String _newOrderId() {
    const digits = '0123456789abcdef';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var index = 0; index < 36; index++) {
      if ([8, 13, 18, 23].contains(index)) {
        buffer.write('-');
      } else if (index == 14) {
        buffer.write('4');
      } else if (index == 19) {
        buffer.write(digits[8 + random.nextInt(4)]);
      } else {
        buffer.write(digits[random.nextInt(16)]);
      }
    }
    return buffer.toString();
  }

  @override
  void initState() {
    super.initState();
    _cart = widget.initialCart;
    _load();
    _loadAddresses();
  }

  Future<void> _receive(Future<TovoResponse> request) async {
    final response = await request;
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!response.ok) {
        _error = response.content;
        return;
      }
      _error = null;
      _step = 0;
      final carts = response.components.where(
        (component) => component.type == 'cart_summary',
      );
      _cart = carts.isEmpty ? null : carts.first;
    });
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    await _receive(widget.api.get('/cart'));
  }

  Future<void> _quantity(String id, int quantity) async {
    if (_busy || quantity < 0 || quantity > 50) return;
    setState(() => _busy = true);
    await _receive(
      quantity == 0
          ? widget.api.delete('/cart/items/$id')
          : widget.api.patch('/cart/items/$id', {'quantity': quantity}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _cart?.list('items') ?? [];
    // Une erreur ne grise pas le bouton : elle s'affiche, le client corrige et
    // repart. Griser laissait un cul-de-sac (capture du 24/09).
    final canCheckout = !_busy && _cart?.flag('can_checkout') == true;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text('Votre commande'),
          leading: IconButton(
            tooltip: 'Retour aux produits',
            onPressed: _busy && _cart != null
                ? null
                : () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded, color: TovoTheme.ink),
          ),
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  if (!_busy) await _load();
                },
                child: ListView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
                  children: [
                    if (_error != null && items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Column(
                          children: [
                            Text(
                              _error!,
                              style: const TextStyle(color: TovoTheme.danger),
                            ),
                            // « Réessayer » recharge le panier : utile s'il n'a
                            // pas pu se charger, trompeur pour une erreur de
                            // saisie qu'il ne corrige pas.
                            if (_cart == null)
                              TextButton(
                                onPressed: _busy ? null : _load,
                                child: const Text('Réessayer'),
                              ),
                          ],
                        ),
                      ),
                    if (items.isEmpty && !_busy && _error == null) ...[
                      const SizedBox(height: 88),
                      const Icon(
                        Icons.shopping_bag_outlined,
                        size: 52,
                        color: TovoTheme.teal,
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Une envie à ajouter ?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Votre panier est encore vide.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: TovoTheme.inkDoux),
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Revenir aux produits'),
                        ),
                      ),
                    ],
                    if (items.isNotEmpty) ...[
                      Text(
                        _cart!.str('merchant_name'),
                        style: const TextStyle(
                          fontSize: 26,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.7,
                        ),
                      ),
                      if (_cart!.str('blocked_reason').isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          _cart!.str('blocked_reason'),
                          style: const TextStyle(color: TovoTheme.danger),
                        ),
                      ],
                      if (_error != null && _destination != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _error!,
                          style: const TextStyle(color: TovoTheme.danger),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text(
                        'Votre sélection',
                        style: TextStyle(
                          fontSize: 13,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final item in items) _item(item),
                      const SizedBox(height: 28),
                      _amount(
                        'Articles',
                        Money.format(_cart!.money('items_total')),
                      ),
                      if (_cart!.money('discount') > 0)
                        _amount(
                          'Réduction',
                          '−${Money.format(_cart!.money('discount'))}',
                        ),
                      if (_step != 2) _amount('Livraison', 'À calculer'),
                      const SizedBox(height: 28),
                      _deliveryForm(),
                      if (_error != null && _destination == null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: TovoTheme.danger),
                        ),
                      ],
                      if (_step == 2) ...[
                        const SizedBox(height: 28),
                        KeyedSubtree(key: _quoteKey, child: _orderReview()),
                      ],
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: !canCheckout
                              ? null
                              : _step == 2
                              ? _placeOrder
                              : _review,
                          child: Text(
                            _step == 2
                                ? 'Confirmer la commande'
                                : 'Voir le total avec livraison',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deliveryForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Livrer à',
        style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      if (_addressesLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Chargement des adresses…'),
        ),
      if (!_addressesLoading && _addresses.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Aucune adresse localisée. Utilisez votre position actuelle.',
            style: TextStyle(fontSize: 13, color: TovoTheme.inkDoux),
          ),
        ),
      for (final address in _addresses)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            _addressId == address['id']
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            color: TovoTheme.teal,
          ),
          // Le lieu d'abord (« Yantala ») : toutes les adresses
          // s'appelaient « Adresse », l'étiquette par défaut. On ne la
          // montre que si le client lui a donné un vrai nom.
          title: Text(
            '${address['text_hint'] ?? ''}'.trim().isNotEmpty
                ? '${address['text_hint']}'
                : '${address['label'] ?? 'Adresse'}',
          ),
          subtitle: _etiquetteParlante(address['label'])
              ? Text('${address['label']}')
              : null,
          onTap: () => setState(() {
            _addressId = address['id'] as String?;
            _currentPoint = null;
            _error = null;
            _step = 0;
          }),
        ),
      TextButton.icon(
        onPressed: _busy ? null : _useLocation,
        icon: const Icon(Icons.my_location_rounded),
        label: const Text('Utiliser ma position actuelle'),
      ),
      if (_currentPoint != null) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _hint,
          onChanged: (_) => setState(() => _error = null),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Repère pour le livreur (facultatif)',
            hintText: 'Quartier, rue, bâtiment…',
            border: InputBorder.none,
            filled: true,
          ),
        ),
      ],
      const SizedBox(height: 28),
      const Text(
        'Paiement',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      ListTile(
        title: const Text('Espèces à la livraison'),
        leading: Icon(
          _payment == 'cash'
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          color: TovoTheme.teal,
        ),
        onTap: () => setState(() => _payment = 'cash'),
      ),
      ListTile(
        title: const Text('Paiement mobile'),
        subtitle: const Text('Vous pourrez régler avant ou à la livraison.'),
        leading: Icon(
          _payment == 'mobile_money'
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          color: TovoTheme.teal,
        ),
        onTap: () => setState(() => _payment = 'mobile_money'),
      ),
    ],
  );

  Widget _orderReview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Total avant confirmation',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      _amount('Articles', Money.format(_cart!.money('items_total'))),
      if (_cart!.money('discount') > 0)
        _amount('Réduction', '−${Money.format(_cart!.money('discount'))}'),
      _amount('Livraison', Money.format(_cart!.money('delivery_fee'))),
      const SizedBox(height: 10),
      Row(
        children: [
          const Expanded(
            child: Text(
              'À payer',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            Money.format(_cart!.money('total')),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ],
  );

  Widget _amount(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );

  Widget _item(Map<String, dynamic> item) {
    final id = item['item_id'] as String?;
    final quantity = (item['quantity'] as num?)?.toInt() ?? 1;
    final photo = item['image_url'] as String? ?? '';
    final name = '${item['product_name'] ?? ''}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEF0F0))),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((item['selections_label'] as String? ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          item['selections_label'] as String,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: TovoTheme.inkDoux,
                          ),
                        ),
                      ),
                    if (item['is_available'] == false)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Indisponible',
                          style: TextStyle(
                            fontSize: 12,
                            color: TovoTheme.danger,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text(
                      Money.format((item['line_total'] as num?)?.toInt() ?? 0),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (photo.isNotEmpty) ...[
                const SizedBox(width: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: CatalogImage(
                    photo,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: quantity > 1 ? 'Réduire $name' : 'Retirer $name',
                onPressed: _busy || id == null
                    ? null
                    : () => _quantity(id, quantity - 1),
                icon: Icon(
                  quantity > 1
                      ? Icons.remove_rounded
                      : Icons.delete_outline_rounded,
                  size: 20,
                ),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  '$quantity',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Ajouter un $name',
                onPressed:
                    _busy ||
                        id == null ||
                        quantity >= 50 ||
                        item['is_available'] == false
                    ? null
                    : () => _quantity(id, quantity + 1),
                icon: const Icon(Icons.add_rounded, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
