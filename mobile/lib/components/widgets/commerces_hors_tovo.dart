import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../features/carte/carte_commerces.dart';
import '../registry.dart';

/// `commerces_hors_tovo` — où trouver ce que Tovo n'a pas (maquette validée
/// le 01/10).
///
/// Des commerces de Niamey qui ne sont pas sur Tovo, tirés de données
/// publiques : le nom, le type, la rue ou le quartier, la distance, puis
/// « Envoyer un livreur » d'abord et le numéro ensuite. Le livreur passe
/// devant : le client est servi dans les deux cas, et Tovo garde sa chance.
///
/// « Envoyer un livreur » renvoie au serveur la même valeur que la tuile
/// « Oui, envoyez un livreur » : la carte livreur s'ouvre, déjà remplie.
class CommercesHorsTovo extends StatelessWidget {
  const CommercesHorsTovo({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  /// Les icônes 3D de l'écran d'accueil, seulement celles qui existent.
  static const _icones = {
    'supermarche',
    'marche',
    'viande',
    'pain',
    'beaute',
    'electronique',
    'vetements',
    'boutiques',
    'restaurants',
    'grillades',
    'lieu-pharmacie',
  };

  @override
  Widget build(BuildContext context) {
    final items = component.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    final note = component.str('note');
    final surCarte = CarteCommerces.depuisComposant(component);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 4),
              child: _Commerce(
                item: items[i],
                premier: i == 0,
                dernier: i == items.length - 1,
                onInteraction: onInteraction,
              ),
            ),
          // La carte des commerces (07/10) : tous ces commerces sur une
          // carte, le tracé depuis le client jusqu'à celui qu'il choisit.
          if (surCarte.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Material(
                color: const Color(0xFFF0F2EC),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CarteCommerces(
                        commerces: surCarte,
                        onInteraction: onInteraction,
                      ),
                    ),
                  ),
                  child: const SizedBox(
                    height: 46,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.map_outlined,
                          size: 18,
                          color: TovoTheme.ink,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Voir sur la carte',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: TovoTheme.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(
                note,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: TovoTheme.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Commerce extends StatelessWidget {
  const _Commerce({
    required this.item,
    required this.premier,
    required this.dernier,
    required this.onInteraction,
  });

  final Map<String, dynamic> item;
  final bool premier;
  final bool dernier;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final icone = '${item['icone'] ?? ''}';
    final distance = (item['distance_m'] as num?)?.toInt();
    final meta = [
      '${item['type'] ?? ''}',
      '${item['adresse'] ?? ''}',
      if (distance != null) Money.distance(distance),
    ].where((s) => s.isNotEmpty).join(' · ');
    final telephone = '${item['telephone'] ?? ''}';
    final livreur = item['livreur'] is Map
        ? Map<String, dynamic>.from(item['livreur'] as Map)
        : const <String, dynamic>{};

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F6),
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(premier ? 22 : 6),
          bottom: Radius.circular(dernier ? 22 : 6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Image.asset(
                  'assets/icons/3d/${CommercesHorsTovo._icones.contains(icone) ? icone : 'boutiques'}.png',
                  width: 34,
                  height: 34,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item['nom'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: TovoTheme.policeNoms,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                        color: TovoTheme.ink,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          meta,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: TovoTheme.inkDoux,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if ('${livreur['value'] ?? ''}'.isNotEmpty)
                // Sans icône : le texte suffit (demande du fondateur, 02/10).
                _Pilule(
                  texte: 'Envoyer un livreur',
                  plein: true,
                  onTap: () => onInteraction(
                    TovoInteraction('quick_reply', {
                      'value': livreur['value'],
                      'label': livreur['label'] ?? 'Envoyer un livreur',
                    }),
                  ),
                ),
              if (telephone.isNotEmpty)
                _Pilule(
                  icone: Icons.call_rounded,
                  texte: telephone,
                  plein: false,
                  onTap: () => onInteraction(
                    TovoInteraction('call_phone', {
                      'phone': item['telephone_appel'] ?? telephone,
                    }),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pilule extends StatelessWidget {
  const _Pilule({
    this.icone,
    required this.texte,
    required this.plein,
    required this.onTap,
  });

  final IconData? icone;
  final String texte;
  final bool plein;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final couleur = plein ? Colors.white : const Color(0xFF202020);
    return Material(
      color: plein ? const Color(0xFF202020) : Colors.white,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icone != null) ...[
                Icon(icone, size: 17, color: couleur),
                const SizedBox(width: 7),
              ],
              Text(
                texte,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: couleur,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
