import 'package:flutter/material.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import '../../core/catalog_image.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key, required this.api});
  final TovoApi api;

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  TovoComponent? _cart;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
    final canCheckout =
        !_busy && _error == null && _cart?.flag('can_checkout') == true;
    return PopScope(
      canPop: !_busy || _cart == null,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text('Votre panier'),
          leading: IconButton(
            tooltip: 'Retour aux produits',
            onPressed: _busy && _cart != null
                ? null
                : () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded, color: TovoTheme.ink),
          ),
        ),
        bottomNavigationBar: items.isEmpty
            ? null
            : SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: TovoTheme.line)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Avant livraison',
                              style: TextStyle(
                                fontSize: 13,
                                color: TovoTheme.inkDoux,
                              ),
                            ),
                          ),
                          Text(
                            Money.format(_cart!.money('total')),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      if (_cart!.str('blocked_reason').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            _cart!.str('blocked_reason'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: TovoTheme.danger,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: canCheckout
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            children: [
                              Expanded(child: Text('Choisir la livraison')),
                              Icon(Icons.arrow_forward_rounded, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
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
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Column(
                          children: [
                            Text(
                              _error!,
                              style: const TextStyle(color: TovoTheme.danger),
                            ),
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
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(context),
                          child: const Text('Continuer mes achats'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _amount(
                        'Articles',
                        Money.format(_cart!.money('items_total')),
                      ),
                      if (_cart!.money('discount') > 0)
                        _amount(
                          'Réduction',
                          '−${Money.format(_cart!.money('discount'))}',
                        ),
                      _amount('Livraison', 'À calculer'),
                      const SizedBox(height: 14),
                      const Text(
                        'Les frais de livraison seront affichés après le choix de votre adresse, avant confirmation.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: TovoTheme.inkDoux,
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
