import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../registry.dart';

/// `option_selector` — choix des options avant l'ajout au panier.
///
/// Le total affiché est recalculé localement à chaque tap, pour que
/// l'utilisateur voie le prix bouger. Ce n'est qu'un affichage : le backend
/// refait le calcul à la réception et fait autorité. Si les deux divergent,
/// c'est le backend qui a raison — et c'est un bug à corriger côté serveur,
/// jamais un écart à rattraper ici.
class OptionSelector extends StatefulWidget {
  const OptionSelector({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  State<OptionSelector> createState() => _OptionSelectorState();
}

class _OptionSelectorState extends State<OptionSelector> {
  /// option_id → valeurs retenues.
  final Map<String, Set<String>> _choix = {};
  int _quantite = 1;

  List<Map<String, dynamic>> get _options => widget.component.list('options');

  @override
  void initState() {
    super.initState();
    _quantite = widget.component.money('quantity', 1);
  }

  int get _prixUnitaire {
    var total = widget.component.money('base_price');
    for (final option in _options) {
      final retenues = _choix[option['id'] as String? ?? ''] ?? const <String>{};
      for (final valeur in (option['values'] as List? ?? const [])) {
        if (valeur is! Map) continue;
        if (retenues.contains(valeur['id'])) {
          total += (valeur['price_delta'] as num?)?.toInt() ?? 0;
        }
      }
    }
    return total;
  }

  /// Le bouton reste inerte tant qu'une option obligatoire n'est pas
  /// satisfaite. La base refuserait l'ajout de toute façon, mais lui laisser
  /// découvrir l'erreur après un aller-retour réseau serait cruel.
  bool get _complet {
    for (final option in _options) {
      final requise = option['required'] as bool? ?? false;
      if (!requise) continue;
      final minimum = (option['min_select'] as num?)?.toInt() ?? 1;
      final retenues = _choix[option['id'] as String? ?? ''] ?? const <String>{};
      if (retenues.length < (minimum < 1 ? 1 : minimum)) return false;
    }
    return true;
  }

  void _basculer(Map<String, dynamic> option, String valeurId) {
    final optionId = option['id'] as String? ?? '';
    final maximum = (option['max_select'] as num?)?.toInt() ?? 1;
    final retenues = _choix.putIfAbsent(optionId, () => <String>{});

    setState(() {
      if (retenues.contains(valeurId)) {
        retenues.remove(valeurId);
      } else if (maximum <= 1) {
        // Choix unique : la nouvelle valeur remplace l'ancienne.
        retenues
          ..clear()
          ..add(valeurId);
      } else if (retenues.length < maximum) {
        retenues.add(valeurId);
      }
    });
  }

  void _confirmer() {
    widget.onInteraction(TovoInteraction('add_to_cart', {
      'product_id': widget.component.str('product_id'),
      'quantity': _quantite,
      'selections': _choix.entries
          .where((e) => e.value.isNotEmpty)
          .map((e) => {'option_id': e.key, 'value_ids': e.value.toList()})
          .toList(),
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x12000000)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.component.str('product_name'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: TovoTheme.ink,
                  ),
                ),
              ),
              Text(
                Money.format(widget.component.money('base_price')),
                style: const TextStyle(fontSize: 13, color: TovoTheme.muted),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final option in _options) _BlocOption(
            option: option,
            retenues: _choix[option['id'] as String? ?? ''] ?? const <String>{},
            onTap: (valeurId) => _basculer(option, valeurId),
          ),
          Row(
            children: [
              const Text(
                'Quantité',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                onPressed: _quantite > 1 ? () => setState(() => _quantite--) : null,
                icon: const Icon(Icons.remove_circle_outline, size: 20),
              ),
              Text(
                '$_quantite',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              IconButton(
                onPressed: () => setState(() => _quantite++),
                icon: const Icon(Icons.add_circle_outline, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FilledButton(
            onPressed: _complet ? _confirmer : null,
            child: Text(
              '${widget.component.str('confirm_label', 'Ajouter au panier')} — '
              '${Money.format(_prixUnitaire * _quantite)}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlocOption extends StatelessWidget {
  const _BlocOption({
    required this.option,
    required this.retenues,
    required this.onTap,
  });

  final Map<String, dynamic> option;
  final Set<String> retenues;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final valeurs = (option['values'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final requise = option['required'] as bool? ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                (option['name'] as String?) ?? '',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: TovoTheme.ink,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                requise ? 'obligatoire' : 'facultatif',
                style: TextStyle(
                  fontSize: 10,
                  color: requise ? TovoTheme.danger : TovoTheme.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final valeur in valeurs)
                _Chip(
                  valeur: valeur,
                  selectionnee: retenues.contains(valeur['id']),
                  onTap: () => onTap(valeur['id'] as String? ?? ''),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.valeur,
    required this.selectionnee,
    required this.onTap,
  });

  final Map<String, dynamic> valeur;
  final bool selectionnee;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final delta = (valeur['price_delta'] as num?)?.toInt() ?? 0;
    final disponible = valeur['available'] as bool? ?? true;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: disponible ? onTap : null,
      child: Opacity(
        opacity: disponible ? 1 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selectionnee ? TovoTheme.tealSoft : TovoTheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selectionnee ? TovoTheme.teal : const Color(0x14000000),
              width: selectionnee ? 1.4 : 1,
            ),
          ),
          child: Text(
            delta == 0
                ? ((valeur['name'] as String?) ?? '')
                : '${valeur['name']}  +${Money.format(delta)}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: selectionnee ? FontWeight.w700 : FontWeight.w500,
              color: selectionnee ? TovoTheme.teal : TovoTheme.ink,
            ),
          ),
        ),
      ),
    );
  }
}
