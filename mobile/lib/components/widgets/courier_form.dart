import 'package:flutter/material.dart';

import '../../core/location.dart';
import '../../core/theme.dart';
import '../registry.dart';

/// `courier_form` — envoi d'un colis d'un point à un autre.
///
/// Le seul composant qui collecte plusieurs informations avant d'agir. Il se
/// remplit progressivement : le backend réémet le formulaire complété à
/// chaque tour plutôt que d'ouvrir une fenêtre modale, ce qui laisse la
/// conversation visible et permet de corriger en parlant.
///
/// L'estimation n'apparaît qu'une fois les deux points connus, et elle vient
/// de la base — les coefficients sont dans `platform_settings`, pilotés par
/// l'admin.
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

class _PointColis {
  _PointColis({this.lat, this.lng, this.hint = ''});
  double? lat;
  double? lng;
  String hint;

  bool get complet => lat != null && lng != null && hint.trim().isNotEmpty;
  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lng': lng,
    'hint': hint.trim(),
  };
}

class _CourierFormState extends State<CourierForm> {
  late final _depart = _lire('pickup');
  late final _arrivee = _lire('dropoff');

  late final TextEditingController _departHint = TextEditingController(
    text: _depart.hint,
  );
  late final TextEditingController _arriveeHint = TextEditingController(
    text: _arrivee.hint,
  );

  /// Le numéro de celui qui reçoit le colis.
  ///
  /// Obligatoire, et c'est le seul champ qui l'est en plus des deux points.
  /// Un livreur devant une porte close sans numéro à appeler repart avec le
  /// paquet, et la course est perdue pour tout le monde.
  late final TextEditingController _contactArrivee = TextEditingController(
    text: widget.component.map('dropoff')['contact'] as String? ?? '',
  );

  late String _colis = widget.component.str('parcel', 'small');
  bool _immediat = true;
  bool _localisationEnCours = false;

  _PointColis _lire(String cle) {
    final brut = widget.component.map(cle);
    return _PointColis(
      lat: (brut['lat'] as num?)?.toDouble(),
      lng: (brut['lng'] as num?)?.toDouble(),
      hint: (brut['hint'] as String?) ?? '',
    );
  }

  @override
  void dispose() {
    _departHint.dispose();
    _arriveeHint.dispose();
    _contactArrivee.dispose();
    super.dispose();
  }

  /// Un numéro nigérien utilisable tel quel.
  ///
  /// On accepte les espaces et l'indicatif : les gens les écrivent comme ils
  /// les lisent. Huit chiffres au minimum une fois nettoyé — en dessous, ce
  /// n'est pas un numéro, et le découvrir devant la porte est trop tard.
  static String _chiffres(String brut) => brut.replaceAll(RegExp(r'[^\d]'), '');

  bool get _contactValide => _chiffres(_contactArrivee.text).length >= 8;

  Future<void> _utiliserMaPosition(_PointColis point) async {
    setState(() => _localisationEnCours = true);
    final position = await TovoLocation.current();
    if (!mounted) return;

    setState(() {
      _localisationEnCours = false;
      if (position != null) {
        point.lat = position.latitude;
        point.lng = position.longitude;
      }
    });

    if (position == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Activez la localisation pour utiliser ce bouton.'),
        ),
      );
    }
  }

  bool get _pretAEnvoyer {
    _depart.hint = _departHint.text;
    _arrivee.hint = _arriveeHint.text;
    return _depart.complet && _arrivee.complet && _contactValide;
  }

  void _envoyer() {
    _depart.hint = _departHint.text;
    _arrivee.hint = _arriveeHint.text;

    widget.onInteraction(
      TovoInteraction('submit_courier', {
        'pickup': _depart.toJson(),
        'dropoff': _arrivee.toJson(),
        'dropoff_contact': _contactArrivee.text.trim(),
        'parcel': _colis,
        'scheduled_for': _immediat ? null : 'later',
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final estimation = widget.component.map('estimate');
    final prix = (estimation['price'] as num?)?.toInt();
    final distance = (estimation['distance_m'] as num?)?.toInt();

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
          const Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: TovoTheme.tealSoft,
                child: Icon(
                  Icons.local_shipping_rounded,
                  color: TovoTheme.teal,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Envoyer un colis',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    Text(
                      'Deux points, et Tovo s’occupe du trajet.',
                      style: TextStyle(fontSize: 11.5, color: TovoTheme.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _Point(
            couleur: TovoTheme.teal,
            titre: 'Prise en charge',
            controller: _departHint,
            hint: 'Ex. : Plateau, boutique Issa',
            positionne: _depart.lat != null,
            occupe: _localisationEnCours,
            onPosition: () => _utiliserMaPosition(_depart),
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 14),
          _Point(
            couleur: TovoTheme.danger,
            titre: 'Livraison',
            controller: _arriveeHint,
            hint: 'Ex. : Yantala, face à la station',
            positionne: _arrivee.lat != null,
            occupe: _localisationEnCours,
            onPosition: () => _utiliserMaPosition(_arrivee),
            onChanged: () => setState(() {}),
          ),

          // Juste sous le point de livraison, parce que c'est la même
          // question : où, et chez qui.
          const SizedBox(height: 12),
          TextField(
            controller: _contactArrivee,
            keyboardType: TextInputType.phone,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Téléphone du destinataire',
              hintText: '90 00 00 00',
              helperText: _contactValide
                  ? 'Le livreur pourra l’appeler en arrivant.'
                  : 'Obligatoire : sans numéro, le livreur repart avec le colis.',
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.call_outlined, size: 20),
              filled: true,
              fillColor: TovoTheme.bloc,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
                borderSide: BorderSide.none,
              ),
            ),
          ),

          const Divider(height: 28),

          const Text(
            'Taille du colis',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final option in widget.component.list('parcel_options'))
                _Chip(
                  libelle: '${option['icon'] ?? ''} ${option['label'] ?? ''}'
                      .trim(),
                  detail: option['hint'] as String?,
                  selectionne: _colis == option['value'],
                  onTap: () => setState(() => _colis = '${option['value']}'),
                ),
            ],
          ),

          const SizedBox(height: 16),
          const Text(
            'Quand ?',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Chip(
                libelle: '⚡ Maintenant',
                selectionne: _immediat,
                onTap: () => setState(() => _immediat = true),
              ),
              const SizedBox(width: 8),
              _Chip(
                libelle: '📅 Programmer',
                selectionne: !_immediat,
                onTap: () => setState(() => _immediat = false),
              ),
            ],
          ),

          if (prix != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: TovoTheme.tealMist,
                borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Estimation',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (distance != null)
                          Text(
                            Money.distance(distance),
                            style: const TextStyle(
                              fontSize: 11,
                              color: TovoTheme.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    Money.format(prix),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: TovoTheme.tealDeep,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),
          FilledButton(
            // Tant que les deux points ne sont pas posés, le bouton reste
            // inerte : il n'y a rien à estimer ni à envoyer, et un bouton
            // actif qui échoue est pire qu'un bouton grisé.
            onPressed: _pretAEnvoyer ? _envoyer : null,
            child: Text(
              prix != null
                  ? 'Confirmer l’envoi — ${Money.format(prix)}'
                  : 'Estimer le prix',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (!_pretAEnvoyer)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Indiquez les deux adresses et touchez « ma position » pour chacune.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: TovoTheme.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({
    required this.couleur,
    required this.titre,
    required this.controller,
    required this.hint,
    required this.positionne,
    required this.occupe,
    required this.onPosition,
    required this.onChanged,
  });

  final Color couleur;
  final String titre;
  final TextEditingController controller;
  final String hint;
  final bool positionne;
  final bool occupe;
  final VoidCallback onPosition;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 18),
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: couleur, shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titre.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: TovoTheme.muted,
                  letterSpacing: 0.6,
                ),
              ),
              TextField(
                controller: controller,
                onChanged: (_) => onChanged(),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFAAAAAA),
                  ),
                  isDense: true,
                  border: InputBorder.none,
                ),
              ),
            ],
          ),
        ),
        // À Niamey, l'adresse postale n'existe pas : le repère écrit ne
        // suffit jamais, il faut l'épingle. Le bouton devient vert une fois
        // la position prise, pour que ce soit visible d'un coup d'œil.
        IconButton(
          onPressed: occupe ? null : onPosition,
          tooltip: 'Utiliser ma position',
          icon: Icon(
            positionne ? Icons.my_location : Icons.location_searching,
            size: 20,
            color: positionne ? TovoTheme.success : TovoTheme.muted,
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.libelle,
    required this.selectionne,
    required this.onTap,
    this.detail,
  });

  final String libelle;
  final String? detail;
  final bool selectionne;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selectionne ? TovoTheme.tealSoft : TovoTheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selectionne ? TovoTheme.teal : const Color(0x14000000),
            width: selectionne ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              libelle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selectionne ? FontWeight.w700 : FontWeight.w500,
                color: selectionne ? TovoTheme.teal : TovoTheme.ink,
              ),
            ),
            if (detail != null)
              Text(
                detail!,
                style: const TextStyle(fontSize: 9, color: TovoTheme.muted),
              ),
          ],
        ),
      ),
    );
  }
}
