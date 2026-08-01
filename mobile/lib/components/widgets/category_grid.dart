import 'package:flutter/material.dart';

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
            childAspectRatio: 0.95,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final id = item['id'] as String?;

            return InkWell(
              borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
              onTap: id == null
                  ? null
                  : () => onInteraction(
                        TovoInteraction('select_category', {'category_id': id}),
                      ),
              child: Container(
                decoration: BoxDecoration(
                  color: TovoTheme.surface,
                  borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
                  border: Border.all(color: const Color(0x11000000)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      (item['icon'] as String?) ?? '🛍️',
                      style: const TextStyle(fontSize: 26),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        (item['name'] as String?) ?? '',
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: TovoTheme.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
