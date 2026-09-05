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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [TovoTheme.tealDeep, TovoTheme.teal],
        ),
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        boxShadow: TovoTheme.ombreFlottante,
      ),
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.center_focus_strong_rounded,
              size: 27,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 13),
          Text(
            component.str(
              'message',
              'Montrez-moi une photo, je trouve où l’acheter',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (camera)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    backgroundColor: Colors.white,
                    foregroundColor: TovoTheme.tealDeep,
                  ),
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
                    minimumSize: const Size(0, 44),
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0x66FFFFFF)),
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
