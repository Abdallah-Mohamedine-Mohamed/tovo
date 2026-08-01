import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `quick_replies` — puces de réponse rapide.
class QuickReplies extends StatelessWidget {
  const QuickReplies({
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

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          ActionChip(
            label: Text(
              (item['label'] as String?) ?? '',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: TovoTheme.tealSoft,
            side: const BorderSide(color: Color(0x22006666)),
            labelStyle: const TextStyle(color: TovoTheme.teal),
            onPressed: () => onInteraction(
              TovoInteraction('quick_reply', {
                'value': item['value'] ?? '',
                'label': item['label'] ?? '',
              }),
            ),
          ),
      ],
    );
  }
}
