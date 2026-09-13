import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/catalog_image.dart';
import '../registry.dart';

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
    final browse = component.map('browse');
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final height =
        258.0 +
        (scale - 1).clamp(0, 2) * 126 +
        (items.any((item) => item['requires_options'] == true) ? 28 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (component.str('title').isNotEmpty)
          Padding(
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
        if (horizontal)
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (_, index) => SizedBox(
                width: 190,
                child: _ProductTile(
                  data: items[index],
                  onInteraction: onInteraction,
                ),
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
        if (browse.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFF4F5F5),
                  foregroundColor: TovoTheme.ink,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () =>
                    onInteraction(TovoInteraction('browse_catalog', browse)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Parcourir les ${browse['total'] ?? items.length} produits',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
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

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.data, required this.onInteraction});
  final Map<String, dynamic> data;
  final InteractionCallback onInteraction;
  @override
  Widget build(BuildContext context) {
    final available = data['is_available'] != false;
    final photo = data['image_url'] as String?;
    final placeholder = ColoredBox(
      color: const Color(0xFFF4F5F5),
      child: Center(
        child: Text(
          'Photo indisponible',
          style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: available,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: available ? () => _open(data, onInteraction) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 132,
                width: double.infinity,
                child: photo == null || photo.isEmpty
                    ? placeholder
                    : CatalogImage(
                        photo,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => placeholder,
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${data['name'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: TovoTheme.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${data['merchant_name'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
            ),
            if (data['requires_options'] == true)
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text(
                  'En option · à personnaliser',
                  maxLines: 2,
                  style: TextStyle(fontSize: 11, color: TovoTheme.teal),
                ),
              ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _price(data),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: TovoTheme.ink,
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  height: 40,
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 20,
                    color: available ? TovoTheme.ink : TovoTheme.muted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
