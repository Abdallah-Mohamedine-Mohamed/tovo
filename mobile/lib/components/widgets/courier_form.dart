import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../features/adresse/choix_adresse.dart';
import '../../core/theme.dart';
import '../registry.dart';
import 'numero_nita.dart';

/// `courier_form` — la carte livreur : RÉCUPÉRER À → LIVRER À.
///
/// Maquette « Carte de course Tovo », version 6 validée le 09/10 : un trajet,
/// deux lieux qu'on touche pour les modifier (« Chez moi » prérempli), une
/// consigne pour le livreur, espèces ou Nita, le prix, puis « Commander un
/// livreur ». Style iOS : sections très claires, icônes au trait noir,
/// aucun trait de séparation.
///
/// Le client est à un bout du trajet… ou à aucun : « chercher un colis à
/// Harobanda et l'amener à Banifandou » (09/10, S4/R4). Avant, la carte ne
/// connaissait que « venir chez moi » et « aller chercher », et livrait chez
/// le client ce qui devait aller ailleurs.
///
/// Un livreur, pas un formulaire : au Niger on n'écrit pas une adresse, on
/// appelle un livreur et le reste se règle au téléphone. Seule la position
/// du client est indispensable — le téléphone la connaît déjà.
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

/// Ce que la base écrit quand le lieu est le client lui-même : ce n'est pas
/// un lieu à afficher.
const _chezLeClient = 'Chez le client';

/// Un bout du trajet : chez le client, ou un lieu dit (avec, peut-être, sa
/// position et un numéro à appeler sur place).
class _Lieu {
  _Lieu({
    this.chezMoi = false,
    this.texte = '',
    this.lat,
    this.lng,
    this.contact = '',
  });

  bool chezMoi;
  String texte;
  double? lat;
  double? lng;
  String contact;

  bool get vide => !chezMoi && texte.trim().isEmpty;
}

// Les couleurs de la maquette V6.
const _section = Color(0xFFFAFBF9);
const _gris = Color(0xFF8A918E);
const _segment = Color(0xFFEEF0EE);

class _CourierFormState extends State<CourierForm> {
  late final Map<String, dynamic> _pickup = widget.component.map('pickup');
  late final Map<String, dynamic> _dropoff = widget.component.map('dropoff');

  bool get _recupererDonne => widget.component.str('mode') == 'recuperer';

  /// Le départ : chez le client, sauf « aller chercher » ou un lieu dit.
  late final _Lieu _depart = _lire(
    _pickup,
    chezMoiParDefaut: !_recupererDonne,
    contact: widget.component.str('pickup_contact', ''),
  );

  /// L'arrivée : chez le client pour « aller chercher », sinon le lieu dit
  /// (facultatif : le livreur appelle pour le reste).
  late final _Lieu _arrivee = _lire(
    _dropoff,
    chezMoiParDefaut: _recupererDonne,
    contact: widget.component.str('dropoff_contact', ''),
  );

  static double? _num(Object? v) => (v as num?)?.toDouble();

  static bool _hintChezClient(String hint) => const {
    _chezLeClient,
    'Chez vous',
    'Chez moi',
    'Position du client',
    'Ma position actuelle',
  }.contains(hint.trim());

  _Lieu _lire(
    Map<String, dynamic> m, {
    required bool chezMoiParDefaut,
    required String contact,
  }) {
    final hint = ((m['hint'] as String?) ?? '').trim();
    final chezMoi = m['chez_moi'] is bool
        ? m['chez_moi'] as bool
        : (hint.isEmpty ? chezMoiParDefaut : _hintChezClient(hint));
    return _Lieu(
      chezMoi: chezMoi,
      texte: chezMoi ? '' : hint,
      lat: chezMoi ? null : _num(m['lat']),
      lng: chezMoi ? null : _num(m['lng']),
      contact: contact,
    );
  }

  /// La position du CLIENT : là où le livreur vient, là où il livre, ou —
  /// pour un trajet entre deux lieux — celle que le serveur a jointe.
  late final Map<String, dynamic> _ouEstLeClient = _depart.chezMoi
      ? _pickup
      : _arrivee.chezMoi
      ? _dropoff
      : widget.component.map('position');
  late double? _lat = _num(_ouEstLeClient['lat']);
  late double? _lng = _num(_ouEstLeClient['lng']);

  /// L'endroit du client choisi sur la carte (plutôt que sa position), et
  /// son nom lisible : « Près du Marché de Talladjé ».
  String? _lieuClient;

  late String _consigne = widget.component.str('consigne', '');
  String _paiement = 'cash';

  /// Un lieu modifié : le prix estimé par le serveur ne vaut plus, la base
  /// recalcule à la commande.
  bool _prixAJour = true;

  /// Le numéro Nita qui paiera (8 chiffres), quand le paiement est Nita.
  String? _numeroNita;

  /// Nita choisi sans numéro complet : l'achat ne pourrait pas être réglé.
  bool get _nitaIncomplet => _paiement == 'mobile_money' && _numeroNita == null;
  bool _localisation = false;

  /// La commande est partie et attend la réponse du serveur. La carte ne
  /// s'éteint qu'avec `utilise`, posé par l'écran quand le serveur a
  /// CONFIRMÉ (26/09).
  bool _envoye = false;

  bool get _commandee => widget.component.data['utilise'] == true;

  /// La dernière tentative a échoué (`echec` posé par l'écran) : on le dit,
  /// et le bouton revient. Jamais de nouvel essai automatique.
  bool get _echec => widget.component.data['echec'] != null;

  /// Ancienne carte « commande d'elle-même » (`auto`) : le serveur ne
  /// l'envoie plus (décision D1), mais une conversation ancienne peut la
  /// porter.
  bool get _auto => widget.component.data['auto'] == true;

  /// Le client est au départ, à l'arrivée, ou nulle part (un trajet entre
  /// deux lieux) : sa position n'est indispensable que dans les deux
  /// premiers cas… et pour trouver un livreur près de lui dans le troisième.
  bool get _positionConnue => _lat != null && _lng != null;

  @override
  void didUpdateWidget(CourierForm ancien) {
    super.didUpdateWidget(ancien);
    // Un nouvel échec : la tentative en cours est terminée.
    if (widget.component.data['echec'] != ancien.component.data['echec'] &&
        _echec) {
      _envoye = false;
    }
  }

  @override
  void initState() {
    super.initState();
    if (_commandee) return;
    if (!_positionConnue) {
      // Une position de moins de 2 minutes : le client n'a pas bougé. Plus
      // vieille (celle de l'ouverture de l'app), on en cherche une fraîche.
      final recente = TovoLocation.recente;
      if (recente != null &&
          DateTime.now().difference(recente.timestamp) <
              const Duration(minutes: 2)) {
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
    if (!_auto ||
        _envoye ||
        _commandee ||
        _echec ||
        !_depart.chezMoi ||
        !_positionConnue) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_envoye) _appeler();
    });
  }

  /// [discret] : lancée d'office à l'ouverture ; en cas d'échec, « Ma
  /// position » reste proposé, sans message qui surgit.
  Future<void> _prendreMaPosition({bool discret = false}) async {
    if (!_localisation) setState(() => _localisation = true);
    final position = await TovoLocation.current(requestPermission: true);
    if (!mounted) return;
    setState(() {
      _localisation = false;
      if (position != null) {
        _lat = position.latitude;
        _lng = position.longitude;
        _lieuClient = null;
      }
    });
    if (position != null) _commanderSiAuto();
  }

  // ---------------------------------------------------------------- modifier

  /// « Modifier » un bout du trajet : chez moi, un lieu écrit, ou un point
  /// sur la carte — et le numéro à appeler sur place.
  Future<void> _modifier(_Lieu lieu, {required bool depart}) async {
    final r = await _ouvrirFeuille(
      _Feuille(
        titre: depart ? 'Récupérer à' : 'Livrer à',
        texte: lieu.texte,
        exemple: depart
            ? 'Chez Moussa, Harobanda'
            : 'Banifandou, près du marché',
        numero: lieu.contact,
        exempleNumero: depart
            ? 'Numéro sur place (facultatif)'
            : 'Numéro du destinataire (facultatif)',
        avecLieux: true,
      ),
    );
    if (!mounted || r == null) return;

    if (r.choix == 'carte') {
      final choisie = await choisirAdresse(
        context,
        api: TovoApi(),
        depart: lieu.lat != null && lieu.lng != null
            ? (lat: lieu.lat!, lng: lieu.lng!)
            : (_positionConnue ? (lat: _lat!, lng: _lng!) : null),
        action: depart ? 'Le livreur vient ici' : 'Livrer ici',
        autrePersonne: !depart,
        enregistrable: false,
      );
      if (!mounted || choisie == null) return;
      setState(() {
        lieu
          ..chezMoi = false
          ..texte = [
            choisie.titre,
            if (choisie.indication.isNotEmpty) choisie.indication,
          ].join(' · ')
          ..lat = choisie.lat
          ..lng = choisie.lng
          ..contact = (choisie.contactTelephone ?? '').isNotEmpty
              ? choisie.contactTelephone!
              : r.numero;
        _prixAJour = false;
      });
      return;
    }
    setState(() {
      if (r.choix == 'chez_moi' || (r.texte.isEmpty && depart)) {
        lieu
          ..chezMoi = true
          ..texte = ''
          ..lat = null
          ..lng = null;
      } else if (r.texte != lieu.texte || lieu.chezMoi) {
        lieu
          ..chezMoi = false
          ..texte = r.texte
          // Un lieu réécrit : l'ancienne position ne lui correspond plus.
          ..lat = null
          ..lng = null;
      }
      lieu.contact = r.numero;
      _prixAJour = false;
    });
  }

  Future<void> _modifierConsigne() async {
    final r = await _ouvrirFeuille(
      _Feuille(
        titre: 'Pour le livreur',
        texte: _consigne,
        exemple: 'Sonner au portail bleu',
        lignes: 3,
      ),
    );
    if (!mounted || r == null) return;
    setState(() => _consigne = r.texte);
  }

  Future<_Choix?> _ouvrirFeuille(_Feuille feuille) =>
      showModalBottomSheet<_Choix>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => feuille,
      );

  // ---------------------------------------------------------------- commander

  void _appeler() {
    setState(() => _envoye = true);
    final depart = _depart;
    final arrivee = _arrivee;
    // La sorte de course que la base connaît (migration 0059) : « aller
    // chercher » quand le client est à l'arrivée seulement ; sinon
    // « déposer », départ et arrivée tels quels (un trajet A → B compris).
    final recuperer = !depart.chezMoi && arrivee.chezMoi;
    final ici = _lieuClient ?? _chezLeClient;

    // Le départ : chez le client, sa position ; ailleurs, la position du lieu
    // si elle est connue, sinon celle du client, autour de laquelle un
    // livreur est cherché.
    final departPoint = depart.chezMoi || recuperer || depart.lat == null
        ? {'lat': _lat, 'lng': _lng}
        : {'lat': depart.lat, 'lng': depart.lng};
    // L'arrivée n'a de position utile que si le départ en a une vraie : sinon
    // la base mesurerait une distance depuis le client, fausse.
    final departReel = depart.chezMoi || depart.lat != null;
    final arriveePoint = arrivee.chezMoi
        ? {'lat': _lat, 'lng': _lng}
        : arrivee.lat != null && departReel && !recuperer
        ? {'lat': arrivee.lat, 'lng': arrivee.lng}
        : null;

    widget.onInteraction(
      TovoInteraction('submit_courier', {
        if (recuperer) 'mode': 'recuperer',
        'pickup': {
          ...departPoint,
          'hint': depart.chezMoi ? ici : depart.texte.trim(),
        },
        if (depart.contact.isNotEmpty) 'pickup_contact': depart.contact,
        'dropoff_hint': arrivee.chezMoi ? ici : arrivee.texte.trim(),
        if (arriveePoint != null) 'dropoff': arriveePoint,
        if (arrivee.contact.isNotEmpty) 'dropoff_contact': arrivee.contact,
        if (_consigne.trim().isNotEmpty) 'parcel_note': _consigne.trim(),
        'payment_method': _paiement,
        if (_paiement == 'mobile_money' && _numeroNita != null)
          'payment_phone': _numeroNita,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Commandée : le suivi, juste en dessous, prend le relais. Plus de ligne
    // « Livreur commandé » qui le répétait (maquette V6).
    if (_commandee) return const SizedBox.shrink();

    final estimation = widget.component.map('estimate');
    final prix = _prixAJour ? (estimation['price'] as num?)?.toInt() : null;
    final forfait = estimation['flat'] == true;
    final distance = (estimation['distance_m'] as num?)?.toInt();
    final mobileMoney = widget.component.data['mobile_money'] == true;
    final pret =
        _positionConnue && !_envoye && !_nitaIncomplet && !_depart.vide;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1414201E),
            blurRadius: 30,
            offset: Offset(0, 10),
          ),
          BoxShadow(
            color: Color(0x0D14201E),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Le trajet : deux lieux, bien espacés, sans trait.
          _Section(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
            child: Column(
              children: [
                _LigneLieu(
                  icone: Icons.inventory_2_outlined,
                  libelle: 'Récupérer à',
                  valeur: _depart.chezMoi
                      ? 'Chez moi'
                      : (_depart.texte.isEmpty
                            ? 'Où aller chercher ?'
                            : _depart.texte),
                  vide: _depart.vide,
                  detail: _depart.chezMoi ? _detailClient() : _depart.contact,
                  action: _depart.vide ? 'Ajouter' : 'Modifier',
                  onAction: _envoye
                      ? null
                      : () => _modifier(_depart, depart: true),
                ),
                const _Pointilles(),
                _LigneLieu(
                  icone: Icons.location_on_outlined,
                  libelle: _arrivee.vide ? 'Livrer à · facultatif' : 'Livrer à',
                  valeur: _arrivee.chezMoi
                      ? 'Chez moi'
                      : (_arrivee.texte.isEmpty
                            ? 'Où l’apporter ?'
                            : _arrivee.texte),
                  vide: _arrivee.vide,
                  detail: _arrivee.chezMoi ? _detailClient() : _arrivee.contact,
                  action: _arrivee.vide ? 'Ajouter' : 'Modifier',
                  onAction: _envoye
                      ? null
                      : () => _modifier(_arrivee, depart: false),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // La consigne, dite pour le livreur.
          _Section(
            padding: const EdgeInsets.all(16),
            child: _LigneLieu(
              icone: Icons.chat_bubble_outline,
              libelle: 'Pour le livreur',
              valeur: _consigne.isEmpty ? 'Aucune consigne' : _consigne,
              vide: _consigne.isEmpty,
              grasse: false,
              action: _consigne.isEmpty ? 'Ajouter' : 'Modifier',
              onAction: _envoye ? null : _modifierConsigne,
            ),
          ),
          if (mobileMoney) ...[
            const SizedBox(height: 14),
            _Segmente(
              valeur: _paiement,
              onChanged: _envoye ? null : (v) => setState(() => _paiement = v),
            ),
            if (_paiement == 'mobile_money') ...[
              const SizedBox(height: 10),
              NumeroNita(
                actif: !_envoye,
                onChanged: (numero) => setState(() => _numeroNita = numero),
              ),
            ],
          ],
          if (_echec && !_envoye) ...[
            const SizedBox(height: 12),
            const Text(
              'La commande n’est pas partie. Touchez le bouton pour réessayer.',
              key: Key('livreur-echec'),
              style: TextStyle(fontSize: 13, color: TovoTheme.inkDoux),
            ),
          ],
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    prix == null
                        ? 'Prix calculé à la commande'
                        : forfait
                        ? 'Course en ville'
                        : distance != null
                        ? 'Course · ${Money.distance(distance)}'
                        : 'Course',
                    style: const TextStyle(fontSize: 15, color: _gris),
                  ),
                ),
                if (prix != null)
                  Text(
                    Money.format(prix),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          if (!_positionConnue && !_envoye) ...[
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: _localisation ? null : () => _prendreMaPosition(),
                child: Text(_localisation ? 'Recherche…' : 'Ma position'),
              ),
            ),
          ],
          const SizedBox(height: 14),
          // Le MÊME bouton que « Commander » sur la fiche produit (teal,
          // texte blanc, pilule) : commander, c'est un seul geste.
          FilledButton(
            onPressed: pret ? _appeler : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: TovoTheme.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: const StadiumBorder(),
            ),
            child: Text(
              _envoye
                  ? 'Je commande le livreur…'
                  : _localisation && _auto
                  ? 'Je cherche votre position…'
                  : 'Commander un livreur',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// Sous « Chez moi » : l'endroit choisi sur la carte, s'il y en a un.
  String _detailClient() => _lieuClient ?? '';
}

// ------------------------------------------------------------------ morceaux

class _Section extends StatelessWidget {
  const _Section({required this.child, required this.padding});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: _section,
      borderRadius: BorderRadius.circular(18),
    ),
    padding: padding,
    child: child,
  );
}

/// Une ligne de la carte : icône au trait, libellé gris, valeur, et l'action
/// (« Modifier », « Ajouter ») en texte teal.
class _LigneLieu extends StatelessWidget {
  const _LigneLieu({
    required this.icone,
    required this.libelle,
    required this.valeur,
    required this.action,
    required this.onAction,
    this.vide = false,
    this.grasse = true,
    this.detail = '',
  });

  final IconData icone;
  final String libelle;
  final String valeur;
  final String action;
  final VoidCallback? onAction;
  final bool vide;
  final bool grasse;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icone, size: 24, color: TovoTheme.ink),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(libelle, style: const TextStyle(fontSize: 13, color: _gris)),
            const SizedBox(height: 2),
            Text(
              valeur,
              style: TextStyle(
                fontSize: grasse ? 17 : 16,
                fontWeight: grasse && !vide ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: -0.2,
                color: vide ? _gris : TovoTheme.ink,
              ),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(detail, style: const TextStyle(fontSize: 14, color: _gris)),
            ],
          ],
        ),
      ),
      TextButton(
        onPressed: onAction,
        style: TextButton.styleFrom(
          foregroundColor: TovoTheme.teal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(44, 44),
        ),
        child: Text(action, style: const TextStyle(fontSize: 15)),
      ),
    ],
  );
}

/// Trois petits points entre les deux lieux, sous l'icône.
class _Pointilles extends StatelessWidget {
  const _Pointilles();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 11, top: 4, bottom: 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Column(
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 2,
              height: 2,
              margin: const EdgeInsets.symmetric(vertical: 2.5),
              decoration: const BoxDecoration(
                color: Color(0xFFB8BDBA),
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Espèces | Nita : deux choix visibles, en pilule (style iOS). Un
/// interrupteur ne dirait pas clairement « espèces » une fois éteint.
class _Segmente extends StatelessWidget {
  const _Segmente({required this.valeur, required this.onChanged});

  final String valeur;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: _segment,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      children: [
        for (final (cle, libelle) in const [
          ('cash', 'Espèces'),
          ('mobile_money', 'Nita'),
        ])
          Expanded(
            child: GestureDetector(
              onTap: onChanged == null ? null : () => onChanged!(cle),
              child: AnimatedContainer(
                duration: TovoTheme.vif,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: valeur == cle ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: valeur == cle
                      ? const [
                          BoxShadow(
                            color: Color(0x1F14201E),
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  libelle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: valeur == cle
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: TovoTheme.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Ce que la feuille rend : le geste (« texte » validé, « chez_moi »,
/// « carte »), et ce qui était écrit.
typedef _Choix = ({String choix, String texte, String numero});

/// La feuille « Modifier » : elle possède ses champs, et les libère
/// elle-même une fois fermée — pas pendant l'animation de fermeture.
class _Feuille extends StatefulWidget {
  const _Feuille({
    required this.titre,
    required this.texte,
    required this.exemple,
    this.numero,
    this.exempleNumero = '',
    this.avecLieux = false,
    this.lignes = 1,
  });

  final String titre;
  final String texte;
  final String exemple;
  final String? numero;
  final String exempleNumero;
  final bool avecLieux;
  final int lignes;

  @override
  State<_Feuille> createState() => _FeuilleState();
}

class _FeuilleState extends State<_Feuille> {
  late final _texte = TextEditingController(text: widget.texte);
  late final _numero = TextEditingController(text: widget.numero ?? '');

  @override
  void dispose() {
    _texte.dispose();
    _numero.dispose();
    super.dispose();
  }

  void _rendre(String choix) => Navigator.of(context).pop<_Choix>((
    choix: choix,
    texte: _texte.text.trim(),
    numero: _numero.text.trim(),
  ));

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      20,
      20,
      20 + MediaQuery.of(context).viewInsets.bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.titre,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        _ChampFeuille(
          controller: _texte,
          exemple: widget.exemple,
          lignes: widget.lignes,
        ),
        if (widget.numero != null) ...[
          const SizedBox(height: 10),
          _ChampFeuille(
            controller: _numero,
            exemple: widget.exempleNumero,
            telephone: true,
          ),
        ],
        if (widget.avecLieux) ...[
          const SizedBox(height: 14),
          _BoutonFeuille(
            icone: Icons.my_location,
            libelle: 'Chez moi',
            onTap: () => _rendre('chez_moi'),
          ),
          _BoutonFeuille(
            icone: Icons.map_outlined,
            libelle: 'Choisir sur la carte',
            onTap: () => _rendre('carte'),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton(
          onPressed: () => _rendre('texte'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            backgroundColor: TovoTheme.teal,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
          ),
          child: const Text(
            'Valider',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _ChampFeuille extends StatelessWidget {
  const _ChampFeuille({
    required this.controller,
    required this.exemple,
    this.telephone = false,
    this.lignes = 1,
  });

  final TextEditingController controller;
  final String exemple;
  final bool telephone;
  final int lignes;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: !telephone,
    minLines: 1,
    maxLines: lignes,
    keyboardType: telephone ? TextInputType.phone : TextInputType.text,
    textCapitalization: telephone
        ? TextCapitalization.none
        : TextCapitalization.sentences,
    style: const TextStyle(fontSize: 16),
    decoration: InputDecoration(
      hintText: exemple,
      filled: true,
      fillColor: _section,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class _BoutonFeuille extends StatelessWidget {
  const _BoutonFeuille({
    required this.icone,
    required this.libelle,
    required this.onTap,
  });

  final IconData icone;
  final String libelle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: TovoTheme.ink,
      alignment: Alignment.centerLeft,
      minimumSize: const Size.fromHeight(44),
    ),
    icon: Icon(icone, size: 20),
    label: Text(libelle, style: const TextStyle(fontSize: 15)),
  );
}
