import 'package:flutter/material.dart';

import '../../core/location.dart';
import '../../core/theme.dart';
import '../registry.dart';

/// `courier_form` — « Un livreur vient chez vous ».
///
/// Un livreur, pas un formulaire. Au Niger on n'écrit pas une adresse : on
/// appelle un livreur, il vient, et le reste se règle au téléphone. La carte
/// ne demande donc qu'une chose, la position, que le téléphone connaît déjà.
/// Destination et destinataire sont facultatifs, rangés sous « Ajouter des
/// détails » — ouverts d'office si le client les a déjà donnés en parlant.
///
/// Un seul geste : « Appeler un livreur ».
class CourierForm extends StatefulWidget {
  const CourierForm({
    super.key,
    required this.component,
    required this.onInteraction,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  State<CourierForm> createState() => _CourierFormState();
}

class _CourierFormState extends State<CourierForm> {
  late final Map<String, dynamic> _pickup = widget.component.map('pickup');
  late final Map<String, dynamic> _dropoff = widget.component.map('dropoff');

  late double? _lat = (_pickup['lat'] as num?)?.toDouble();
  late double? _lng = (_pickup['lng'] as num?)?.toDouble();

  late final _repere = TextEditingController();
  late final _destination = TextEditingController(
    text: (_dropoff['hint'] as String?) ?? '',
  );
  late final _destinataire = TextEditingController(
    text: widget.component.str('dropoff_contact', ''),
  );

  late bool _details =
      _destination.text.isNotEmpty || _destinataire.text.isNotEmpty;
  String _paiement = 'cash';
  bool _localisation = false;
  bool _envoye = false;

  @override
  void dispose() {
    _repere.dispose();
    _destination.dispose();
    _destinataire.dispose();
    super.dispose();
  }

  Future<void> _prendreMaPosition() async {
    setState(() => _localisation = true);
    final position = await TovoLocation.current(requestPermission: true);
    if (!mounted) return;
    setState(() {
      _localisation = false;
      if (position != null) {
        _lat = position.latitude;
        _lng = position.longitude;
      }
    });
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Activez la localisation pour que le livreur vous trouve.',
          ),
        ),
      );
    }
  }

  void _appeler() {
    final repere = _repere.text.trim();
    final dropLat = (_dropoff['lat'] as num?)?.toDouble();
    final dropLng = (_dropoff['lng'] as num?)?.toDouble();
    setState(() => _envoye = true);
    widget.onInteraction(
      TovoInteraction('submit_courier', {
        'pickup': {
          'lat': _lat,
          'lng': _lng,
          'hint': repere.isEmpty ? 'Position du client' : repere,
        },
        'dropoff_hint': _destination.text.trim(),
        if (dropLat != null && dropLng != null)
          'dropoff': {'lat': dropLat, 'lng': dropLng},
        'dropoff_contact': _destinataire.text.trim(),
        'payment_method': _paiement,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final estimation = widget.component.map('estimate');
    final prix = (estimation['price'] as num?)?.toInt();
    final forfait = estimation['flat'] == true;
    final distance = (estimation['distance_m'] as num?)?.toInt();
    final minutes =
        (widget.component.data['callback_minutes'] as num?)?.toInt() ?? 7;
    final mobileMoney = widget.component.data['mobile_money'] == true;
    final positionConnue = _lat != null && _lng != null;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        boxShadow: TovoTheme.ombreFlottante,
      ),
      padding: const EdgeInsets.all(17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Un livreur vient chez vous',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Il vous appelle dans les $minutes minutes pour les détails.',
            style: const TextStyle(fontSize: 13, color: TovoTheme.muted),
          ),
          const SizedBox(height: 16),

          // Le seul point requis : où le livreur doit venir.
          Row(
            children: [
              Icon(
                positionConnue ? Icons.my_location : Icons.location_searching,
                size: 20,
                color: positionConnue ? TovoTheme.teal : TovoTheme.muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  positionConnue
                      ? 'Ma position actuelle'
                      : 'Où le livreur doit-il venir ?',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!positionConnue)
                TextButton(
                  onPressed: _localisation ? null : _prendreMaPosition,
                  child: Text(_localisation ? 'Recherche…' : 'Ma position'),
                ),
            ],
          ),

          // Tout le reste est facultatif, et replié.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _details = !_details),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                foregroundColor: TovoTheme.inkDoux,
              ),
              icon: Icon(
                _details ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: const Text(
                'Ajouter des détails (facultatif)',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          ),
          if (_details) ...[
            _Champ(
              controller: _repere,
              libelle: 'Un repère chez vous',
              exemple: 'Face à la pharmacie',
              icone: Icons.place_outlined,
            ),
            const SizedBox(height: 8),
            _Champ(
              controller: _destination,
              libelle: 'Destination',
              exemple: 'Yantala, près du marché',
              icone: Icons.flag_outlined,
            ),
            const SizedBox(height: 8),
            _Champ(
              controller: _destinataire,
              libelle: 'Numéro du destinataire',
              exemple: '90 00 00 00',
              icone: Icons.call_outlined,
              telephone: true,
            ),
            const SizedBox(height: 6),
          ],

          if (mobileMoney) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final (valeur, libelle) in const [
                  ('cash', 'Espèces'),
                  ('mobile_money', 'Nita'),
                ])
                  ChoiceChip(
                    label: Text(libelle),
                    selected: _paiement == valeur,
                    onSelected: (_) => setState(() => _paiement = valeur),
                  ),
              ],
            ),
          ],

          const Divider(height: 26),
          Row(
            children: [
              Expanded(
                child: Text(
                  prix == null
                      ? (mobileMoney
                            ? 'Paiement au livreur'
                            : 'Espèces, au livreur')
                      : forfait
                      ? 'Course en ville'
                      : distance != null
                      ? 'Course · ${Money.distance(distance)}'
                      : 'Course',
                  style: const TextStyle(
                    fontSize: 13,
                    color: TovoTheme.inkDoux,
                  ),
                ),
              ),
              if (prix != null)
                Text(
                  Money.format(prix),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: positionConnue && !_envoye ? _appeler : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            child: const Text(
              'Appeler un livreur',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _Champ extends StatelessWidget {
  const _Champ({
    required this.controller,
    required this.libelle,
    required this.exemple,
    required this.icone,
    this.telephone = false,
  });

  final TextEditingController controller;
  final String libelle;
  final String exemple;
  final IconData icone;
  final bool telephone;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: telephone ? TextInputType.phone : TextInputType.text,
    textCapitalization: telephone
        ? TextCapitalization.none
        : TextCapitalization.sentences,
    style: const TextStyle(fontSize: 14),
    decoration: InputDecoration(
      labelText: libelle,
      hintText: exemple,
      isDense: true,
      prefixIcon: Icon(icone, size: 19),
      filled: true,
      fillColor: TovoTheme.bloc,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
