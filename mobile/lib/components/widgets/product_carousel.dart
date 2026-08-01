import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `product_carousel` et `product_list` — deux rendus, une même donnée.
class ProductCollection extends StatelessWidget {
  const ProductCollection({
    super.key,
    required this.component,
    required this.onInteraction,
    required this.horizontal,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;
  final bool horizontal;

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
        if (horizontal)
          SizedBox(
            height: 208,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) => SizedBox(
                width: 156,
                child: _ProductTile(data: items[i], onInteraction: onInteraction),
              ),
            ),
          )
        else
          Column(
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ProductRow(data: item, onInteraction: onInteraction),
                ),
            ],
          ),
      ],
    );
  }
}

String _prix(Map<String, dynamic> data) => Money.format((data['price'] as num?)?.toInt() ?? 0);

void _ouvrir(Map<String, dynamic> data, InteractionCallback onInteraction) {
  final id = data['id'] as String?;
  if (id == null) return;
  onInteraction(TovoInteraction('select_product', {'product_id': id}));
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.data, required this.onInteraction});

  final Map<String, dynamic> data;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final disponible = data['is_available'] as bool? ?? true;

    return Opacity(
      opacity: disponible ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        onTap: disponible ? () => _ouvrir(data, onInteraction) : null,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
            border: Border.all(color: const Color(0x12000000)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Vignette(url: data['image_url'] as String?, height: 104),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (data['name'] as String?) ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: TovoTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (data['merchant_name'] as String?) ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _prix(data),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: TovoTheme.teal,
                      ),
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
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.data, required this.onInteraction});

  final Map<String, dynamic> data;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final distance = (data['distance_m'] as num?)?.toInt();
    final disponible = data['is_available'] as bool? ?? true;

    return Opacity(
      opacity: disponible ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        onTap: disponible ? () => _ouvrir(data, onInteraction) : null,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
            border: Border.all(color: const Color(0x12000000)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _Vignette(url: data['image_url'] as String?, height: 56, width: 56),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (data['name'] as String?) ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: TovoTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        (data['merchant_name'] as String?) ?? '',
                        if (distance != null) Money.distance(distance),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _prix(data),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: TovoTheme.teal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder tramé quand l'image manque ou ne charge pas — fréquent sur un
/// réseau instable, et un carré gris vaut mieux qu'une icône d'erreur.
class _Vignette extends StatelessWidget {
  const _Vignette({required this.url, required this.height, this.width});

  final String? url;
  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      height: height,
      width: width ?? double.infinity,
      color: const Color(0xFFEBEBEB),
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, color: Color(0xFFBDBDBD), size: 20),
    );

    if (url == null || url!.isEmpty) return placeholder;

    return Image.network(
      url!,
      height: height,
      width: width ?? double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
}
