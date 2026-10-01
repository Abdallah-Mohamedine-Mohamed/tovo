import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../components/widgets/carte_suivi_theme.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import 'recherche_lieu.dart';

/// L'endroit choisi sur la carte, et ce que le livreur doit savoir.
class AdresseChoisie {
  const AdresseChoisie({
    required this.lat,
    required this.lng,
    required this.titre,
    this.quartier,
    this.indication = '',
    this.contactNom,
    this.contactTelephone,
  });

  final double lat;
  final double lng;

  /// « Près du Marché de Talladjé », ou le quartier, ou « Point sur la carte ».
  final String titre;
  final String? quartier;

  /// « Portail bleu, 2ᵉ rue après la pharmacie ».
  final String indication;

  /// Livrer à quelqu'un d'autre : son prénom et son téléphone.
  final String? contactNom;
  final String? contactTelephone;

  bool get pourAutrui =>
      (contactNom ?? '').isNotEmpty || (contactTelephone ?? '').isNotEmpty;

  /// Ce que lit le livreur, en une ligne (300 caractères au plus côté
  /// serveur) : l'indication, le repère et le quartier, la personne à
  /// livrer.
  String get pourLivreur {
    final lieu = quartier == null || titre.contains(quartier!)
        ? titre
        : '$titre ($quartier)';
    final personne = pourAutrui
        ? 'Livrer à ${[contactNom, contactTelephone].where((v) => (v ?? '').isNotEmpty).join(', ')}'
        : null;
    final ligne = [
      if (indication.isNotEmpty) indication,
      lieu,
      ?personne,
    ].join(' · ');
    return ligne.length > 300 ? ligne.substring(0, 300) : ligne;
  }
}

/// Choisir où livrer, sur la carte (maquette du 28/09).
///
/// Une épingle au centre, la carte glisse dessous. Sous l'épingle, le repère
/// le plus proche tiré de nos lieux OpenStreetMap (« Près du Marché de
/// Talladjé ») : le livreur sait où aller, sans service payant. En haut,
/// chercher un quartier ou un repère ; en bas, une indication, et — pour
/// commander pour quelqu'un d'autre — son prénom et son téléphone.
///
/// Toujours en carte claire : on y cherche des rues, pas une ambiance.
Future<AdresseChoisie?> choisirAdresse(
  BuildContext context, {
  required TovoApi api,
  ({double lat, double lng})? depart,
  String action = 'Livrer ici',
  bool autrePersonne = true,
  bool enregistrable = true,
}) => Navigator.of(context).push<AdresseChoisie>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ChoixAdresseScreen(
      api: api,
      depart: depart,
      action: action,
      autrePersonne: autrePersonne,
      enregistrable: enregistrable,
    ),
  ),
);

class ChoixAdresseScreen extends StatefulWidget {
  const ChoixAdresseScreen({
    required this.api,
    this.depart,
    this.action = 'Livrer ici',
    this.autrePersonne = true,
    this.enregistrable = true,
    super.key,
  });

  final TovoApi api;
  final ({double lat, double lng})? depart;
  final String action;
  final bool autrePersonne;
  final bool enregistrable;

  @override
  State<ChoixAdresseScreen> createState() => _ChoixAdresseScreenState();
}

class _ChoixAdresseScreenState extends State<ChoixAdresseScreen> {
  static const _niamey = LatLng(TovoLocation.niameyLat, TovoLocation.niameyLng);

  GoogleMapController? _carte;
  late LatLng _centre;
  bool _bouge = false;

  // Ce que dit l'endroit de l'épingle.
  String? _repere;
  String? _quartier;
  bool _nommage = false;
  int _generation = 0;

  final _indication = TextEditingController();
  final _nom = TextEditingController();
  final _telephone = TextEditingController();
  bool _pourAutrui = false;
  bool _enregistrer = false;
  String _etiquette = 'Maison';
  bool _envoi = false;

  final _feuille = GlobalKey();
  double _hauteurFeuille = 330;

  @override
  void initState() {
    super.initState();
    final depart = widget.depart;
    final recente = TovoLocation.recente;
    _centre = depart != null
        ? LatLng(depart.lat, depart.lng)
        : recente != null
        ? LatLng(recente.latitude, recente.longitude)
        : _niamey;
    unawaited(_nommer(_centre));
    // Pas de point de départ ni de position récente : on la cherche, et la
    // carte y va dès qu'elle est trouvée.
    if (depart == null && recente == null) unawaited(_allerAMaPosition());
  }

  @override
  void dispose() {
    _indication.dispose();
    _nom.dispose();
    _telephone.dispose();
    super.dispose();
  }

  /// La feuille change de hauteur (« pour quelqu'un d'autre » ouvert) :
  /// l'épingle et le centre de la carte restent au milieu de ce qui est
  /// visible au-dessus d'elle.
  void _mesurerFeuille() {
    final taille = _feuille.currentContext?.size;
    if (taille != null && (taille.height - _hauteurFeuille).abs() > 1) {
      setState(() => _hauteurFeuille = taille.height);
    }
  }

  Future<void> _nommer(LatLng point) async {
    final generation = ++_generation;
    setState(() => _nommage = true);
    final reponse = await widget.api.get(
      '/lieux/autour',
      query: {'lat': point.latitude, 'lng': point.longitude},
    );
    if (!mounted || generation != _generation) return;
    final repere = reponse.raw['repere'];
    setState(() {
      _nommage = false;
      _repere = repere is Map ? '${repere['nom']}' : null;
      _quartier = reponse.raw['quartier'] as String?;
    });
  }

  Future<void> _allerAMaPosition() async {
    final position = await TovoLocation.current(requestPermission: true);
    if (!mounted || position == null) return;
    final ici = LatLng(position.latitude, position.longitude);
    await _carte?.animateCamera(CameraUpdate.newLatLngZoom(ici, 17));
  }

  Future<void> _chercher() async {
    final lieu = await Navigator.of(context).push<LieuTrouve>(
      MaterialPageRoute(builder: (_) => RechercheLieuScreen(api: widget.api)),
    );
    if (!mounted || lieu == null) return;
    await _carte?.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(lieu.lat, lieu.lng),
        lieu.estUnQuartier ? 15.5 : 17.5,
      ),
    );
  }

  String get _titre {
    final repere = _repere;
    if (repere != null) return 'Près de $repere';
    return _quartier ?? 'Point choisi sur la carte';
  }

  Future<void> _valider() async {
    if (_envoi) return;
    final choix = AdresseChoisie(
      lat: _centre.latitude,
      lng: _centre.longitude,
      titre: _titre,
      quartier: _quartier,
      indication: _indication.text.trim(),
      contactNom: _pourAutrui ? _nom.text.trim() : null,
      contactTelephone: _pourAutrui ? _telephone.text.trim() : null,
    );
    if (_enregistrer) {
      setState(() => _envoi = true);
      // Enregistrée pour la prochaine fois ; un échec ne bloque pas la
      // commande en cours — l'adresse est déjà choisie.
      await widget.api.post('/addresses', {
        'label': _etiquette,
        'text_hint': choix.pourLivreur,
        'lat': choix.lat,
        'lng': choix.lng,
      });
      if (!mounted) return;
    }
    Navigator.of(context).pop(choix);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _mesurerFeuille());
    final marges = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: ThemeCarte.clair.fond,
        body: LayoutBuilder(
          builder: (context, contraintes) {
            final hauteurCarte = contraintes.maxHeight - _hauteurFeuille + 24;
            return Stack(
              children: [
                Positioned.fill(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _centre,
                      zoom: 16.5,
                    ),
                    style: ThemeCarte.clair.style,
                    // Le centre de la carte = le milieu de la partie visible,
                    // au-dessus de la feuille : c'est là qu'est l'épingle.
                    padding: EdgeInsets.only(
                      bottom: _hauteurFeuille - 24,
                      top: marges.top,
                    ),
                    onMapCreated: (carte) => _carte = carte,
                    onCameraMoveStarted: () => setState(() => _bouge = true),
                    onCameraMove: (position) => _centre = position.target,
                    onCameraIdle: () {
                      setState(() => _bouge = false);
                      unawaited(_nommer(_centre));
                    },
                    rotateGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    zoomControlsEnabled: false,
                    myLocationButtonEnabled: false,
                    myLocationEnabled: false,
                    mapToolbarEnabled: false,
                    compassEnabled: false,
                    buildingsEnabled: false,
                    minMaxZoomPreference: const MinMaxZoomPreference(11, 19),
                  ),
                ),
                // L'épingle : elle se soulève pendant que la carte glisse.
                Positioned(
                  left: 0,
                  right: 0,
                  top: (marges.top + hauteurCarte) / 2 - 64,
                  child: IgnorePointer(
                    child: AnimatedSlide(
                      duration: TovoTheme.vif,
                      offset: Offset(0, _bouge ? -0.12 : 0),
                      child: _Epingle(texte: widget.action),
                    ),
                  ),
                ),
                Positioned(
                  top: marges.top + 8,
                  left: 16,
                  right: 16,
                  child: Row(
                    children: [
                      _BoutonFlottant(
                        etiquette: 'Retour',
                        onTap: () => Navigator.of(context).maybePop(),
                        child: const Icon(
                          Icons.arrow_back_rounded,
                          color: TovoTheme.ink,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Material(
                          color: Colors.white,
                          elevation: 3,
                          shadowColor: const Color(0x33281C1C),
                          shape: const StadiumBorder(),
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: _chercher,
                            child: const SizedBox(
                              height: 46,
                              child: Row(
                                children: [
                                  SizedBox(width: 16),
                                  Icon(
                                    Icons.search_rounded,
                                    size: 21,
                                    color: TovoTheme.inkDoux,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Quartier, repère…',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: TovoTheme.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: _hauteurFeuille + 12 - 24,
                  child: _BoutonFlottant(
                    etiquette: 'Revenir à ma position',
                    onTap: _allerAMaPosition,
                    child: const Icon(
                      Icons.my_location_rounded,
                      color: TovoTheme.ink,
                      size: 21,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _feuilleDeChoix(marges),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _feuilleDeChoix(EdgeInsets marges) {
    InputDecoration champ(String indice) => InputDecoration(
      hintText: indice,
      isDense: true,
      filled: true,
      fillColor: TovoTheme.bloc,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
    const libelle = TextStyle(fontSize: 13, color: TovoTheme.inkDoux);
    return Container(
      key: _feuille,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Color(0x1A281C1C), blurRadius: 24)],
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + marges.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD6DBD4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(widget.action, style: libelle),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: TovoTheme.vif,
            child: Text(
              _nommage && _repere == null && _quartier == null
                  ? 'Recherche du repère…'
                  : _titre,
              key: ValueKey('$_nommage$_titre'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 19,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (_repere != null && _quartier != null) ...[
            const SizedBox(height: 2),
            Text(
              '$_quartier · Niamey',
              style: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _indication,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 120,
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    null,
            decoration: champ('Indication pour le livreur (portail bleu…)'),
          ),
          if (widget.autrePersonne) ...[
            const SizedBox(height: 6),
            const Divider(height: 1, color: TovoTheme.line),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _pourAutrui,
              activeTrackColor: TovoTheme.teal,
              onChanged: (v) => setState(() => _pourAutrui = v),
              title: const Text(
                'Pour quelqu’un d’autre',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            if (_pourAutrui) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nom,
                      textCapitalization: TextCapitalization.words,
                      decoration: champ('Son prénom'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _telephone,
                      keyboardType: TextInputType.phone,
                      decoration: champ('Son téléphone'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Le livreur l’appellera à l’arrivée.',
                style: TextStyle(fontSize: 12.5, color: TovoTheme.inkDoux),
              ),
            ],
          ],
          if (widget.enregistrable) ...[
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _enregistrer,
              activeColor: TovoTheme.ink,
              onChanged: (v) => setState(() => _enregistrer = v ?? false),
              title: const Text(
                'Enregistrer cette adresse',
                style: TextStyle(fontSize: 15),
              ),
            ),
            if (_enregistrer)
              Wrap(
                spacing: 8,
                children: [
                  for (final e in const ['Maison', 'Bureau', 'Famille'])
                    ChoiceChip(
                      label: Text(e),
                      selected: _etiquette == e,
                      showCheckmark: false,
                      selectedColor: TovoTheme.ink,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _etiquette == e ? Colors.white : TovoTheme.ink,
                      ),
                      onSelected: (_) => setState(() => _etiquette = e),
                    ),
                ],
              ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _bouge || _envoi ? null : _valider,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(
              widget.action,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// L'épingle : une pastille sombre, une tige, un point au sol — la même
/// famille que la pastille « Vous » de la carte de suivi.
class _Epingle extends StatelessWidget {
  const _Epingle({required this.texte});

  final String texte;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1F2129),
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color(0x38281C1C),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Text(
          texte,
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFFF4F2EB),
          ),
        ),
      ),
      Container(width: 2, height: 22, color: const Color(0xFF1F2129)),
      Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFF1F2129),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Color(0x291F2129), spreadRadius: 4)],
        ),
      ),
    ],
  );
}

class _BoutonFlottant extends StatelessWidget {
  const _BoutonFlottant({
    required this.etiquette,
    required this.onTap,
    required this.child,
  });

  final String etiquette;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: etiquette,
    child: Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: const Color(0x33281C1C),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 46, height: 46, child: Center(child: child)),
      ),
    ),
  );
}
