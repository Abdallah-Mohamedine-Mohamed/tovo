import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `image_search_prompt` — invitation à photographier.
///
/// L'utilisateur choisit appareil photo ou galerie ; le téléversement est
/// pris en charge par le fil de conversation, qui compresse l'image, la
/// dépose dans Storage et émet `search_by_image` avec le CHEMIN.
///
/// Ce composant ne manipule jamais les octets de l'image : les faire
/// transiter par le contrat les ferait finir dans l'historique de
/// conversation, à chaque tour, pour toujours.
class ImageSearchPrompt extends StatelessWidget {
  const ImageSearchPrompt({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final camera = component.flag('allow_camera', true);
    final galerie = component.flag('allow_gallery', true);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TovoTheme.surface,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x14000000)),
      ),
      child: Column(
        children: [
          const Icon(Icons.photo_camera_outlined, size: 32, color: TovoTheme.teal),
          const SizedBox(height: 10),
          Text(
            component.str('message', 'Montrez-moi une photo, je trouve où l’acheter'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (camera)
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                  onPressed: () => onInteraction(
                    const TovoInteraction('pick_image', {'source': 'camera'}),
                  ),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('Photographier'),
                ),
              if (camera && galerie) const SizedBox(width: 10),
              if (galerie)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 42),
                    foregroundColor: TovoTheme.teal,
                  ),
                  onPressed: () => onInteraction(
                    const TovoInteraction('pick_image', {'source': 'gallery'}),
                  ),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Galerie'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
