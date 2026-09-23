import 'package:flutter/material.dart';

import '../registry.dart';

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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 24),
            child: Text(
              'Vous pouvez aussi demander',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          for (var index = 0; index < items.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: const Color(0xFFF7F7F6),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(index == 0 ? 22 : 5),
                  bottom: Radius.circular(index == items.length - 1 ? 22 : 5),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onInteraction(
                    TovoInteraction('quick_reply', {
                      'value': items[index]['value'] ?? '',
                      'label': items[index]['label'] ?? '',
                    }),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 22,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${items[index]['label'] ?? ''}',
                            style: const TextStyle(fontSize: 15, height: 1.35),
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          size: 22,
                          color: Color(0xFF202020),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
