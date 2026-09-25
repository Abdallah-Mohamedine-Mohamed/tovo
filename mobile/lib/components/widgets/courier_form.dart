import 'package:flutter/material.dart';

import '../../core/location.dart';
import '../../core/theme.dart';
import '../registry.dart';

/// `courier_form` — la carte livreur, dans ses deux sortes.
///
/// « Je veux un livreur » recouvre deux demandes :
///  - **Venir chez moi** : le livreur vient à ma position, je lui remets un
///    colis, il le porte ailleurs.
///  - **Aller chercher** : il va chercher quelque chose ailleurs (« chez
///    Moussa, Harobanda ») et me l'apporte.
///
/// La sorte comprise par le serveur est présélectionnée ; le client en change
/// d'un geste. Un livreur, pas un formulaire : au Niger on n'écrit pas une
/// adresse, on appelle un livreur et le reste se règle au téléphone. Seule la
/// position du client est indispensable — le téléphone la connaît déjà.
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

  late String _mode = widget.component.str('mode', 'deposer') == 'recuperer'
      ? 'recuperer'
      : 'deposer';
  bool get _recuperer => _mode == 'recuperer';

  /// La position du CLIENT : le départ quand il envoie, l'arrivée quand on
  /// lui apporte.
  late double? _lat = _num(_recuperer ? _dropoff['lat'] : _pickup['lat']);
  late double? _lng = _num(_recuperer ? _dropoff['lng'] : _pickup['lng']);

  static double? _num(Object? v) => (v as num?)?.toDouble();

  // Venir chez moi.
  late final _repere = TextEditingController();
  late final _destination = TextEditingController(
    text: _recuperer ? '' : (_dropoff['hint'] as String?) ?? '',
  );
  late final _destinataire = TextEditingController(
    text: widget.component.str('dropoff_contact', ''),
  );

  // Aller chercher.
  late final _ouChercher = TextEditingController(
    text: _recuperer ? (_pickup['hint'] as String?) ?? '' : '',
  );
  late final _contactSurPlace = TextEditingController(
    text: widget.component.str('pickup_contact', ''),
  );

  late bool _details =
      _destination.text.isNotEmpty || _destinataire.text.isNotEmpty;
  String _paiement = 'cash';
  bool _localisation = false;
  late bool _envoye = widget.component.data['utilise'] == true;

  /// « Je veux un livreur », sans plus : la carte commande d'elle-même dès
  /// que la position est connue. Le client l'a déjà dit ; lui faire toucher
  /// un bouton de plus serait le lui redemander.
  bool get _auto => widget.component.data['auto'] == true;

  @override
  void initState() {
    super.initState();
    if (_envoye) return;
    if (_lat == null || _lng == null) {
      // Le client a demandé un livreur : chercher sa position est la suite
      // logique, pas un geste de plus à lui demander. Déjà connue depuis
      // l'ouverture de l'app, elle est là tout de suite.
      final recente = TovoLocation.recente;
      if (recente != null) {
        _lat = recente.latitude;
        _lng = recente.longitude;
      } else {
        _localisation = true;
        _prendreMaPosition(discret: true);
        return;
      }
    }
    _commanderSiAuto();
  }

  void _commanderSiAuto() {
    if (!_auto || _envoye || _recuperer || _lat == null || _lng == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_envoye) _appeler();
    });
  }

  @override
  void dispose() {
    _repere.dispose();
    _destination.dispose();
    _destinataire.dispose();
    _ouChercher.dispose();
    _contactSurPlace.dispose();
    super.dispose();
  }

  /// [discret] : lancée d'office à l'ouverture ; en cas d'échec, le bouton
  /// « Ma position » reste là, sans message qui surgit.
  Future<void> _prendreMaPosition({bool discret = false}) async {
    if (!_localisation) setState(() => _localisation = true);
    final position = await TovoLocation.current(requestPermission: true);
    if (!mounted) return;
    setState(() {
      _localisation = false;
      if (position != null) {
        _lat = position.latitude;
        _lng = position.longitude;
      }
    });
    if (position != null) _commanderSiAuto();
    if (position == null && !discret) {
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
    setState(() => _envoye = true);
    if (_recuperer) {
      final ou = _ouChercher.text.trim();
      widget.onInteraction(
        TovoInteraction('submit_courier', {
          'mode': 'recuperer',
          // Le départ n'est qu'une description ; la position envoyée est
          // celle du client, autour de laquelle un livreur est cherché.
          'pickup': {'lat': _lat, 'lng': _lng, 'hint': ou},
          'pickup_contact': _contactSurPlace.text.trim(),
          'dropoff': {'lat': _lat, 'lng': _lng},
          'dropoff_hint': 'Chez le client',
          'payment_method': _paiement,
        }),
      );
      return;
    }
    final repere = _repere.text.trim();
    final dropLat = _num(_dropoff['lat']);
    final dropLng = _num(_dropoff['lng']);
    widget.onInteraction(
      TovoInteraction('submit_courier', {
        'mode': 'deposer',
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

  /// Après la demande : une ligne, plus de bouton. Le suivi, juste en
  /// dessous dans la conversation, prend le relais.
  Widget _demande(int minutes) => Container(
    decoration: BoxDecoration(
      color: TovoTheme.bloc,
      borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        const Icon(Icons.check_circle, size: 20, color: TovoTheme.teal),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'Livreur commandé',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: ' · il vous appelle dans les $minutes minutes',
                  style: const TextStyle(color: TovoTheme.muted),
                ),
              ],
            ),
            style: const TextStyle(fontSize: 13.5),
          ),
        ),
      ],
    ),
  );

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

    if (_envoye || widget.component.data['utilise'] == true) {
      return _demande(minutes);
    }

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
          // Les deux sortes, d'un geste.
          Wrap(
            spacing: 8,
            children: [
              for (final (valeur, libelle) in const [
                ('deposer', 'Venir chez moi'),
                ('recuperer', 'Aller chercher'),
              ])
                ChoiceChip(
                  label: Text(libelle),
                  selected: _mode == valeur,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _mode = valeur),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _recuperer
                ? 'Un livreur va chercher pour vous'
                : 'Un livreur vient chez vous',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _recuperer
                ? 'Il vous l’apporte, et vous appelle dans les $minutes minutes.'
                : 'Il vous appelle dans les $minutes minutes pour les détails.',
            style: const TextStyle(fontSize: 13, color: TovoTheme.muted),
          ),
          const SizedBox(height: 16),

          if (_recuperer) ...[
            // Ce qui compte ici : OÙ aller chercher. Visible d'office.
            _Champ(
              controller: _ouChercher,
              libelle: 'Où aller chercher ?',
              exemple: 'Chez Moussa, Harobanda',
              icone: Icons.inventory_2_outlined,
            ),
            const SizedBox(height: 8),
            _Champ(
              controller: _contactSurPlace,
              libelle: 'Numéro sur place (facultatif)',
              exemple: '90 00 00 00',
              icone: Icons.call_outlined,
              telephone: true,
            ),
            const SizedBox(height: 14),
          ],

          // Ma position : le départ (venir chez moi) ou l'arrivée (aller
          // chercher).
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
                      ? (_recuperer
                            ? 'Livré à ma position'
                            : 'Ma position actuelle')
                      : (_recuperer
                            ? 'Où vous l’apporter ?'
                            : 'Où le livreur doit-il venir ?'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!positionConnue)
                TextButton(
                  onPressed: _localisation ? null : () => _prendreMaPosition(),
                  child: Text(_localisation ? 'Recherche…' : 'Ma position'),
                ),
            ],
          ),

          if (!_recuperer) ...[
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
                      : forfait || _recuperer
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
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // Le MÊME bouton que « Commander » sur la fiche produit (teal,
          // texte blanc, pilule) : commander, c'est un seul geste dans l'app,
          // une seule couleur. « Commander le livreur » : explicite et court.
          FilledButton(
            onPressed: positionConnue && !_envoye ? _appeler : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              backgroundColor: TovoTheme.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: const StadiumBorder(),
            ),
            child: Text(
              _localisation && _auto
                  ? 'Je cherche votre position…'
                  : 'Commander le livreur',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
