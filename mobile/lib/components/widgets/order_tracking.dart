import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../../core/noms.dart';
import '../../core/live_activity.dart';
import '../../core/position_livreur.dart';
import 'carte_suivi.dart';
import 'suivi_sheet.dart';
import '../registry.dart';
import 'package:flutter/services.dart';
import 'numero_nita.dart';

/// Trois moments pour un repas (29/09) : « confirmée » et « en préparation »
/// ne faisaient qu'une — moins d'une minute les séparait. « Prête » et
/// « récupérée » sont dites par le titre au-dessus.
const List<String> _etapesCommandeVisibles = [
  'En préparation',
  'En route',
  'Livrée',
];

/// Un livreur, trois moments qui comptent pour le client : il vient, il a
/// le colis, c'est livré. « Recherche », « trouvé », « en route » étaient
/// des états internes du dispatch, pas des choses à suivre.
const List<String> _etapesColisVisibles = [
  'Livreur en route',
  'Colis récupéré',
  'Livré',
];

/// « Aller chercher » : il part chercher, il a le colis, il est chez vous.
const List<String> _etapesRecuperationVisibles = [
  'Il part le chercher',
  'Colis récupéré',
  'Livré chez vous',
];

int _etapeColisVisible(String statut) => switch (statut) {
  'pending' || 'confirmed' || 'ready' || 'assigned' => 0,
  'picked_up' || 'delivering' => 1,
  'delivered' => 2,
  _ => -1,
};

/// Un livreur déjà sur une commande en attente (0071 : il la passe sur place)
/// : elle est lancée, comme si la boutique l'avait acceptée.
int _etapeCommandeVisible(String statut, {bool livreur = false}) =>
    switch (statut) {
      'pending' => livreur ? 0 : -1,
      'confirmed' || 'preparing' || 'ready' || 'assigned' => 0,
      'picked_up' || 'delivering' => 1,
      'delivered' => 2,
      _ => -1,
    };

/// La valeur par défaut que la base écrit quand le client n'a pas donné de
/// destination : ce n'est pas une adresse, on ne l'affiche pas comme telle.
const _destinationInconnue = 'À voir avec le client';

/// `order_tracking` — composant vivant.
///
/// Contrairement aux autres, il ne se contente pas d'afficher ce que le
/// backend lui a donné : il s'abonne à Supabase Realtime et se met à jour
/// seul. Le backend n'a donc pas à renvoyer un nouveau composant à chaque
/// changement de statut, et l'utilisateur voit sa commande avancer sans rien
/// rafraîchir.
///
/// Les policies RLS s'appliquent au flux Realtime : le client ne reçoit que
/// les positions du livreur de SA commande, et plus rien une fois livrée.
class OrderTracking extends StatefulWidget {
  const OrderTracking({
    super.key,
    required this.component,
    required this.onInteraction,
    this.grandFormat = false,
    this.onFermer,
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  /// Sur l'écran de suivi : la carte seule, plein écran. Dans le fil de la
  /// conversation (par défaut), pas de carte — un bouton ouvre l'écran.
  final bool grandFormat;

  /// Le bouton retour de l'écran de suivi.
  final VoidCallback? onFermer;

  @override
  State<OrderTracking> createState() => _OrderTrackingState();
}

class _OrderTrackingState extends State<OrderTracking>
    with WidgetsBindingObserver {
  RealtimeChannel? _canalCommande;
  RealtimeChannel? _canalLivreur;
  Timer? _verification;
  bool _lectureEnCours = false;

  late String _statut;
  Map<String, dynamic>? _livreur;

  /// L'état du paiement : « paid » dès que Nita l'a constaté, ou que le
  /// livreur l'a déclaré reçu.
  late String _paiement = widget.component.str('payment_status', 'pending');
  DateTime? _dernierePosition;

  /// La moto sur la carte : glisse d'une position reçue à la suivante.
  final MotoAnimee moto = MotoAnimee();

  /// Change à chaque position reçue : la carte relance la glisse et recadre.
  int _revision = 0;

  /// Note déposée pendant cette session, pour remplacer aussitôt les étoiles
  /// par un remerciement. Sans ça le client ne sait pas si son geste a porté
  /// et note une deuxième fois.
  int? _note;

  static const _termine = {'delivered', 'cancelled'};

  @override
  void initState() {
    super.initState();
    _statut = widget.component.str('status', 'pending');
    _livreur = widget.component.data['driver'] as Map<String, dynamic>?;
    _prendrePosition(_livreur);
    WidgetsBinding.instance.addObserver(this);
    if (_orderId.isNotEmpty && !_termine.contains(_statut)) {
      unawaited(
        TovoLiveActivity.start(
          orderId: _orderId,
          status: _statut,
          courier: widget.component.str('type') == 'courier',
          title: enPhrase(
            widget.component.str('merchant_name', 'Votre livraison'),
          ),
          placedAt: DateTime.tryParse(widget.component.str('placed_at')),
          mode: widget.component.data['mode'] as String?,
          driver: _livreur?['name'] as String?,
        ),
      );
    } else if (_orderId.isNotEmpty) {
      unawaited(
        TovoLiveActivity.sync(
          _orderId,
          _statut,
          driver: _livreur?['name'] as String?,
        ),
      );
    }
    _relire();
    _abonner();
    if (_orderId.isNotEmpty && !_termine.contains(_statut)) {
      _verification = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_relire()),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _desabonner();
    super.dispose();
  }

  /// Relit l'état réel de la commande.
  ///
  /// Le statut affiché venait du composant enregistré dans le message — une
  /// PHOTO prise au moment où le backend a répondu. Le temps réel ne rattrape
  /// que ce qui bouge pendant que l'écran est ouvert et abonné : tout ce qui
  /// s'est passé app fermée, écran éteint ou réseau coupé était perdu pour
  /// de bon. Le client rouvrait Tovo sur « en attente de confirmation » alors
  /// que son repas était devant sa porte.
  ///
  /// D'où cette relecture à chaque montage, et à chaque retour au premier
  /// plan : c'est elle qui rattrape le passé, l'abonnement ne fait que
  /// suivre le présent.
  Future<void> _relire() async {
    if (_orderId.isEmpty || _lectureEnCours || _termine.contains(_statut)) {
      return;
    }
    _lectureEnCours = true;

    try {
      final etat = await Supabase.instance.client.rpc(
        'order_tracking',
        params: {'p_order_id': _orderId},
      );

      if (!mounted || etat is! Map) return;
      final statut = etat['status'] as String?;
      if (statut == null) return;

      setState(() {
        _statut = statut;
        _livreur =
            (etat['driver'] as Map?)?.cast<String, dynamic>() ?? _livreur;
        _paiement = (etat['payment_status'] as String?) ?? _paiement;
        _prendrePosition(_livreur);
      });
      unawaited(
        TovoLiveActivity.sync(
          _orderId,
          statut,
          driver: _livreur?['name'] as String?,
        ),
      );

      // Livrée pendant l'absence : plus rien à écouter, et l'abonnement
      // ouvert coûterait de la batterie pour un événement qui ne viendra pas.
      if (_termine.contains(statut)) _desabonner();
    } on Exception {
      // Réseau muet : la photo du message reste affichée, ce qui vaut mieux
      // qu'une carte vide. Le prochain retour au premier plan réessaiera.
    } finally {
      _lectureEnCours = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    if (etat == AppLifecycleState.resumed) unawaited(_relire());
  }

  String get _orderId => widget.component.str('order_id');

  void _abonner() {
    if (_orderId.isEmpty || _termine.contains(_statut)) return;

    final client = Supabase.instance.client;

    _canalCommande = client
        .channel('tovo:orders:$_orderId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: _orderId,
          ),
          callback: (payload) {
            final nouveau = payload.newRecord['status'] as String?;
            if (nouveau == null || !mounted) return;
            setState(() {
              _statut = nouveau;
              _paiement =
                  (payload.newRecord['payment_status'] as String?) ?? _paiement;
            });
            unawaited(
              TovoLiveActivity.sync(
                _orderId,
                nouveau,
                driver: _livreur?['name'] as String?,
              ),
            );
            if (payload.newRecord['driver_id'] != null && _livreur == null) {
              unawaited(_relire());
            }
            // Commande terminée : plus rien à écouter. Laisser les canaux
            // ouverts consommerait de la batterie et du forfait pour rien.
            if (_termine.contains(nouveau)) _desabonner();
          },
        )
        .subscribe();

    _canalLivreur = client
        .channel('tovo:driver_locations:$_orderId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'driver_locations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: _orderId,
          ),
          callback: (payload) {
            if (!mounted) return;
            final point = lirePoint(payload.newRecord['location']);
            final capDonne = (payload.newRecord['heading'] as num?)?.toDouble();
            final vitesse = (payload.newRecord['speed_kmh'] as num?)
                ?.toDouble();
            setState(() {
              // L'heure du SERVEUR, comme celle que relit _prendrePosition :
              // comparer l'heure du téléphone à celle du serveur faisait
              // rejouer deux fois le même point quand leurs horloges
              // différaient.
              _dernierePosition =
                  DateTime.tryParse(
                    '${payload.newRecord['recorded_at'] ?? ''}',
                  ) ??
                  DateTime.now();
              if (point != null) {
                moto.recevoir(point, capDonne: capDonne, vitesseKmh: vitesse);
                _revision++;
              }
            });
          },
        )
        .subscribe();
  }

  /// La dernière position connue, donnée par le serveur (order_tracking,
  /// migration 0069) : la moto est sur la carte dès l'ouverture.
  void _prendrePosition(Map<String, dynamic>? livreur) {
    final position = livreur?['position'];
    final point = lirePoint(position);
    if (point == null) return;
    final quand = DateTime.tryParse('${(position as Map)['at'] ?? ''}');
    // Relue au retour dans l'app : plus ancienne que la dernière reçue en
    // direct, elle ramènerait la moto en arrière.
    final connue = _dernierePosition;
    if (moto.position() != null &&
        (quand == null || (connue != null && !quand.isAfter(connue)))) {
      return;
    }
    final capDonne = (position['heading'] as num?)?.toDouble();
    moto.recevoir(point, capDonne: capDonne);
    _revision++;
    if (quand != null) _dernierePosition = quand;
  }

  void _desabonner() {
    _verification?.cancel();
    _verification = null;
    if (_canalCommande == null && _canalLivreur == null) return;
    final client = Supabase.instance.client;
    if (_canalCommande != null) client.removeChannel(_canalCommande!);
    if (_canalLivreur != null) client.removeChannel(_canalLivreur!);
    _canalCommande = null;
    _canalLivreur = null;
  }

  static const Map<String, String> _libelles = {
    'pending': 'En attente de confirmation',
    'confirmed': 'En préparation',
    'preparing': 'En préparation',
    'ready': 'Prête, en attente d’un livreur',
    'assigned': 'Un livreur arrive',
    'picked_up': 'En route vers vous',
    'delivering': 'En route vers vous',
    'delivered': 'Livrée',
    'cancelled': 'Annulée',
  };

  /// « Moussa », pas « Moussa Issoufou » : c'est ainsi qu'on l'appelle.
  String get _prenomLivreur {
    final nom = ((_livreur?['name'] as String?) ?? '').trim();
    return nom.isEmpty ? '' : nom.split(RegExp(r'\s+')).first;
  }

  /// « Aller chercher » (migration 0059) : le livreur va chercher ailleurs
  /// et apporte au client.
  bool get _recuperer => widget.component.str('mode') == 'recuperer';

  String _description(bool colis) {
    if (_statut == 'cancelled') return 'Cette commande ne sera pas livrée.';
    if (colis && _recuperer) {
      final minutes =
          (widget.component.data['callback_minutes'] as num?)?.toInt() ?? 7;
      return switch (_statut) {
        'pending' ||
        'confirmed' ||
        'ready' => 'Dans les $minutes minutes, pour convenir des détails.',
        'assigned' => 'Il va chercher votre colis.',
        'picked_up' => 'Il a votre colis et vient vers vous.',
        'delivering' => 'Votre colis est en chemin vers vous.',
        'delivered' => 'Votre colis vous a été remis.',
        _ => 'Suivez votre livraison ici.',
      };
    }
    if (colis) {
      final minutes =
          (widget.component.data['callback_minutes'] as num?)?.toInt() ?? 7;
      return switch (_statut) {
        'pending' ||
        'confirmed' ||
        'ready' => 'Dans les $minutes minutes, pour convenir des détails.',
        'assigned' => 'Il vient à votre position.',
        'picked_up' => 'Le colis a été récupéré par votre livreur.',
        'delivering' => 'Votre colis est en chemin vers sa destination.',
        'delivered' => 'Votre colis est arrivé à destination.',
        _ => 'Suivez votre livraison ici.',
      };
    }
    // Un livreur est dessus avant la récupération : il va à la boutique, et
    // y passe la commande si elle n'a pas l'app (0071).
    if (_livreur != null &&
        const {
          'pending',
          'confirmed',
          'preparing',
          'ready',
          'assigned',
        }.contains(_statut)) {
      return 'Il se rend à la boutique et récupère votre commande.';
    }
    return switch (_statut) {
      'pending' => 'La boutique doit encore confirmer votre commande.',
      'confirmed' => 'La boutique prépare votre commande.',
      'preparing' => 'La boutique prépare votre commande.',
      'ready' => 'Votre commande attend qu’un livreur la récupère.',
      'assigned' => 'Un livreur se rend à la boutique.',
      'picked_up' || 'delivering' => 'Votre commande est en chemin vers vous.',
      'delivered' => 'Votre commande vous a été remise.',
      _ => 'Suivez votre commande ici.',
    };
  }

  /// Le lieu est le client lui-même (ce que la base ou la carte écrivent),
  /// pas un endroit à nommer.
  static bool _chezLeClient(String lieu) => const {
    '',
    'Chez le client',
    'Chez vous',
    'Chez moi',
    'Position du client',
    'Ma position actuelle',
    _destinationInconnue,
  }.contains(lieu.trim());

  /// Le suivi d'une COURSE dans le fil (maquette « Carte de course Tovo »,
  /// V6, 09/10) : le titre d'état, les trois étapes AVEC leurs lieux, la
  /// consigne pour le livreur, le prix, puis les boutons. Le délai d'appel
  /// n'est dit qu'une fois, dans la phrase de Tovo au-dessus.
  Widget _suiviCourse() {
    const gris = Color(0xFF8A918E);
    final annulee = _statut == 'cancelled';
    final annulable =
        _livreur == null &&
        const {'pending', 'confirmed', 'preparing', 'ready'}.contains(_statut);
    final prenom = _prenomLivreur;
    final depart = ((widget.component.map('pickup')['hint'] as String?) ?? '')
        .trim();
    final arrivee = ((widget.component.map('dropoff')['hint'] as String?) ?? '')
        .trim();
    final departClient = _chezLeClient(depart) && !_recuperer;
    final arriveeClient = _recuperer;
    final consigne = widget.component.str('parcel_note').trim();
    final total = widget.component.money('total');

    final titre = switch (_statut) {
      'pending' || 'confirmed' || 'preparing' || 'ready' => 'Livreur demandé',
      'assigned' when departClient =>
        prenom.isEmpty ? 'Votre livreur arrive' : '$prenom arrive',
      'assigned' =>
        prenom.isEmpty
            ? 'Votre livreur part le chercher'
            : '$prenom part le chercher',
      'picked_up' => 'Colis récupéré',
      'delivering' => 'Colis en route',
      'delivered' => 'Colis livré',
      'cancelled' => 'Livraison annulée',
      _ => _statut,
    };
    // Les étapes portent les lieux : le titre ne se répète plus.
    final etapes = <(IconData, String)>[
      (
        Icons.inventory_2_outlined,
        departClient
            ? 'Récupération chez vous'
            : depart.isEmpty || _chezLeClient(depart)
            ? 'Récupération du colis'
            : 'Récupération à $depart',
      ),
      (
        Icons.two_wheeler_outlined,
        arriveeClient
            ? 'En route vers vous'
            : _chezLeClient(arrivee)
            ? 'En route'
            : 'En route vers $arrivee',
      ),
      (Icons.location_on_outlined, 'Livré'),
    ];
    final courante = _etapeColisVisible(_statut);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
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
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_livreur == null && !annulee) ...[
                  const Text(
                    'Votre livraison',
                    style: TextStyle(fontSize: 13, color: gris),
                  ),
                  const SizedBox(height: 4),
                ],
                AnimatedSwitcher(
                  duration: TovoTheme.normal,
                  child: Text(
                    titre,
                    key: ValueKey(titre),
                    style: TextStyle(
                      fontSize: 24,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      color: annulee ? TovoTheme.inkDoux : TovoTheme.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!annulee) ...[
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFAFBF9),
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, (icone, libelle)) in etapes.indexed) ...[
                    if (i > 0) const _DeuxPoints(),
                    Row(
                      children: [
                        Icon(
                          icone,
                          size: 24,
                          color: i <= courante
                              ? TovoTheme.ink
                              : const Color(0xFFA3A9A6),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            libelle,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: i == courante
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: i <= courante ? TovoTheme.ink : gris,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // La consigne, rattachée au trajet (pas un bloc à part).
                  if (consigne.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 38, top: 14),
                      child: Text.rich(
                        TextSpan(
                          text: 'Pour le livreur : ',
                          children: [
                            TextSpan(
                              text: '« $consigne »',
                              style: const TextStyle(color: TovoTheme.ink),
                            ),
                          ],
                        ),
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: gris,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (widget.component.str('payment_method') == 'mobile_money' &&
              !annulee &&
              (_paiement == 'paid' ||
                  (_livreur != null && _statut != 'delivered'))) ...[
            const SizedBox(height: 14),
            _PaiementNita(
              paye: _paiement == 'paid',
              montant: total,
              prenom: prenom,
              telephone: (_livreur?['phone'] as String?) ?? '',
            ),
          ],
          if (total > 0) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.component.str('payment_method') == 'mobile_money'
                          ? 'Nita'
                          : 'Espèces',
                      style: const TextStyle(fontSize: 15, color: gris),
                    ),
                  ),
                  Text(
                    Money.format(total),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_livreur != null && !annulee && _statut != 'delivered') ...[
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => widget.onInteraction(
                TovoInteraction('call_driver', {
                  'phone': _livreur!['phone'] ?? '',
                }),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: TovoTheme.teal,
                foregroundColor: Colors.white,
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.call, size: 19),
              label: Text(
                prenom.isEmpty ? 'Appeler le livreur' : 'Appeler $prenom',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => ouvrirSuivi(
                context,
                component: widget.component,
                onInteraction: widget.onInteraction,
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: const Color(0xFFEEF0EE),
                foregroundColor: TovoTheme.ink,
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.map_outlined, size: 19),
              label: const Text(
                'Suivre sur la carte',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          if (annulable)
            TextButton(
              onPressed: () => widget.onInteraction(
                TovoInteraction('cancel_order', {'order_id': _orderId}),
              ),
              // En rouge : une action qui défait la commande se reconnaît
              // d'un coup d'œil (demande du fondateur, 05/10).
              style: TextButton.styleFrom(
                foregroundColor: TovoTheme.danger,
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text(
                'Annuler la commande',
                style: TextStyle(fontSize: 16),
              ),
            ),
          if (_statut == 'delivered') ...[
            const SizedBox(height: 18),
            _BlocNotation(
              noteDeposee: _note,
              onNoter: (note) {
                setState(() => _note = note);
                widget.onInteraction(
                  TovoInteraction('rate_order', {
                    'order_id': widget.component.str('order_id'),
                    'rating': note,
                  }),
                );
              },
            ),
          ],
          if (!annulable && _statut != 'delivered') const SizedBox(height: 4),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colis = widget.component.str('type', '') == 'courier';
    if (colis && !widget.grandFormat) return _suiviCourse();
    final etapes = colis
        ? (_recuperer ? _etapesRecuperationVisibles : _etapesColisVisibles)
        : _etapesCommandeVisibles;
    final courante = colis
        ? _etapeColisVisible(_statut)
        : _etapeCommandeVisible(_statut, livreur: _livreur != null);
    final annulee = _statut == 'cancelled';
    // Même règle que la base (cancel_my_order) : tant qu'aucun livreur
    // n'est parti. La base tranche de toute façon, ce bouton ne fait
    // qu'éviter de le proposer quand c'est perdu d'avance.
    final annulable =
        _livreur == null &&
        const {'pending', 'confirmed', 'preparing', 'ready'}.contains(_statut);
    final libelle = colis
        ? switch (_statut) {
            'pending' || 'confirmed' || 'ready' => 'Un livreur va vous appeler',
            'assigned' when _recuperer =>
              _prenomLivreur.isEmpty
                  ? 'Votre livreur part le chercher'
                  : '$_prenomLivreur part le chercher',
            'assigned' =>
              _prenomLivreur.isEmpty
                  ? 'Votre livreur arrive'
                  : '$_prenomLivreur arrive',
            'picked_up' => 'Colis récupéré',
            'delivering' when _recuperer => 'Votre colis arrive',
            'delivering' => 'Colis en route',
            'delivered' => 'Colis livré',
            'cancelled' => 'Livraison annulée',
            _ => _statut,
          }
        : _livreur != null &&
              const {
                'pending',
                'confirmed',
                'preparing',
                'ready',
                'assigned',
              }.contains(_statut)
        ? (_prenomLivreur.isEmpty
              ? 'Un livreur va la chercher'
              : '$_prenomLivreur va la chercher')
        : _libelles[_statut] ?? _statut;

    final brute = ((widget.component.map('dropoff')['hint'] as String?) ?? '')
        .trim();
    final destination = brute == _destinationInconnue ? '' : brute;
    final details = [
      if (widget.component.str('merchant_name').isNotEmpty)
        enPhrase(widget.component.str('merchant_name')),
      if (colis && _recuperer)
        'À récupérer : ${(widget.component.map('pickup')['hint'] as String?) ?? 'à préciser au livreur'}'
      else if (destination.isNotEmpty)
        destination
      else if (colis)
        'Destination à préciser au livreur',
      if (widget.component.money('total') > 0)
        Money.format(widget.component.money('total')),
    ];

    final contenu = Padding(
      padding: widget.grandFormat
          ? const EdgeInsets.fromLTRB(24, 22, 24, 28)
          : const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            colis ? 'Votre livraison' : 'Votre commande',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TovoTheme.inkDoux,
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: TovoTheme.normal,
            child: Column(
              key: ValueKey(_statut),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  libelle,
                  style: TextStyle(
                    fontSize: 24,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: annulee ? TovoTheme.inkDoux : TovoTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _description(colis),
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: TovoTheme.inkDoux,
                  ),
                ),
              ],
            ),
          ),
          if (!annulee) ...[
            const SizedBox(height: 20),
            _EtapesVerticales(etapes: etapes, courante: courante),
          ],
          if (_livreur != null && !annulee && _statut != 'delivered') ...[
            const SizedBox(height: 18),
            _BlocLivreur(
              prenom: _prenomLivreur,
              positionRecue: moto.position() != null,
              onVoirLaCarte: widget.grandFormat
                  ? null
                  : () => ouvrirSuivi(
                      context,
                      component: widget.component,
                      onInteraction: widget.onInteraction,
                    ),
              onAppeler: () => widget.onInteraction(
                TovoInteraction('call_driver', {
                  'phone': _livreur!['phone'] ?? '',
                }),
              ),
            ),
          ],
          // Nita : payé, ou la façon la plus simple de le faire — envoyer au
          // livreur, comme on lui donnerait des espèces. Seulement quand un
          // livreur est là : avant, il n'y a personne à qui envoyer.
          if (widget.component.str('payment_method') == 'mobile_money' &&
              !annulee &&
              (_paiement == 'paid' ||
                  (_livreur != null && _statut != 'delivered'))) ...[
            const SizedBox(height: 14),
            _PaiementNita(
              paye: _paiement == 'paid',
              montant: widget.component.money('total'),
              prenom: _prenomLivreur,
              telephone: (_livreur?['phone'] as String?) ?? '',
            ),
          ],
          if (details.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              details.join(' · '),
              style: const TextStyle(
                fontSize: 12,
                height: 1.45,
                color: TovoTheme.inkDoux,
              ),
            ),
          ],
          if (annulable) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => widget.onInteraction(
                TovoInteraction('cancel_order', {'order_id': _orderId}),
              ),
              // En rouge : une action qui défait la commande se reconnaît
              // d'un coup d'œil (demande du fondateur, 05/10).
              style: TextButton.styleFrom(
                foregroundColor: TovoTheme.danger,
                padding: EdgeInsets.zero,
              ),
              child: const Text('Annuler la commande'),
            ),
          ],
          if (_statut == 'delivered') ...[
            const SizedBox(height: 22),
            _BlocNotation(
              noteDeposee: _note,
              onNoter: (note) {
                setState(() => _note = note);
                widget.onInteraction(
                  TovoInteraction('rate_order', {
                    'order_id': widget.component.str('order_id'),
                    'rating': note,
                  }),
                );
              },
            ),
          ],
        ],
      ),
    );
    if (!widget.grandFormat) return contenu;

    // L'écran de suivi : la carte, et rien d'autre (maquette « Suivi
    // Commande », 27/09). L'étape, le livreur, le paiement sont déjà dans
    // le fil, sur l'écran verrouillé et dans la Dynamic Island.
    final depart = lirePoint(
      colis ? widget.component.map('pickup') : widget.component.map('merchant'),
    );
    final client = lirePoint(widget.component.map('dropoff'));
    if (!annulee && (depart != null || client != null)) {
      return CarteSuivi(
        moto: moto,
        revision: _revision,
        orderId: _orderId,
        statut: _statut,
        livreurPresent: _livreur != null,
        depart: depart,
        client: client,
        nomDepart: colis
            ? 'Colis'
            : enPhrase(widget.component.str('merchant_name')),
        colis: colis,
        // Un colis envoyé : l'arrivée est chez le destinataire, pas « vous ».
        clientEstVous: !colis || _recuperer,
        onRetour: widget.onFermer,
      );
    }
    // Annulée, ou aucun lieu connu : rien à montrer sur une carte.
    return ColoredBox(
      color: const Color(0xFF176A73),
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                annulee
                    ? 'Commande annulée'
                    : 'La carte apparaîtra dès que le trajet sera connu.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE9E9ED),
                ),
              ),
            ),
          ),
          if (widget.onFermer != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 16,
              child: IconButton.filled(
                tooltip: 'Retour',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xE6232532),
                  fixedSize: const Size(46, 46),
                ),
                onPressed: widget.onFermer,
                icon: const Icon(
                  Icons.chevron_left_rounded,
                  color: Color(0xFFE9E9ED),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// La progression, de haut en bas : ce qui est fait, où on en est, ce qui
/// vient. Trois ou quatre lignes, pas plus.
class _EtapesVerticales extends StatelessWidget {
  const _EtapesVerticales({required this.etapes, required this.courante});

  final List<String> etapes;
  final int courante;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < etapes.length; i++)
        _Etape(
          libelle: etapes[i],
          faite: i < courante,
          active: i == courante,
          derniere: i == etapes.length - 1,
        ),
    ],
  );
}

class _Etape extends StatelessWidget {
  const _Etape({
    required this.libelle,
    required this.faite,
    required this.active,
    required this.derniere,
  });

  final String libelle;
  final bool faite;
  final bool active;
  final bool derniere;

  @override
  Widget build(BuildContext context) {
    final atteinte = faite || active;
    return SizedBox(
      height: derniere ? 26 : 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: TovoTheme.normal,
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? TovoTheme.teal : Colors.white,
                    border: Border.all(
                      color: atteinte ? TovoTheme.teal : TovoTheme.line,
                      width: 1.5,
                    ),
                  ),
                  child: faite
                      ? const Icon(Icons.check, size: 11, color: TovoTheme.teal)
                      : null,
                ),
                if (!derniere)
                  Expanded(
                    child: AnimatedContainer(
                      duration: TovoTheme.normal,
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: faite ? TovoTheme.teal : TovoTheme.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            libelle,
            style: TextStyle(
              fontSize: 14,
              height: 1.3,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active
                  ? TovoTheme.ink
                  : faite
                  ? TovoTheme.inkDoux
                  : TovoTheme.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Deux petits points entre deux étapes, sous l'icône (maquette V6).
class _DeuxPoints extends StatelessWidget {
  const _DeuxPoints();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 11, top: 5, bottom: 5),
    child: Column(
      children: [
        for (var i = 0; i < 2; i++)
          Container(
            width: 2,
            height: 2,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: const BoxDecoration(
              color: Color(0xFFB8BDBA),
              shape: BoxShape.circle,
            ),
          ),
      ],
    ),
  );
}

/// Cinq étoiles, et rien d'autre.
///
/// Pas de champ de commentaire ici : demander à écrire au moment où le
/// client vient d'être livré fait abandonner la plupart des gens, et une
/// note sans commentaire vaut mieux que pas de note du tout. Le commentaire
/// reste possible par l'API pour qui veut le laisser.
class _BlocNotation extends StatelessWidget {
  const _BlocNotation({required this.noteDeposee, required this.onNoter});

  final int? noteDeposee;
  final ValueChanged<int> onNoter;

  @override
  Widget build(BuildContext context) {
    return noteDeposee != null
        ? Row(
            children: [
              const Icon(
                Icons.favorite_outline,
                size: 18,
                color: TovoTheme.teal,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Merci, votre note est enregistrée.',
                  style: const TextStyle(fontSize: 14, color: TovoTheme.ink),
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Comment s’est passée cette commande ?',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var etoile = 1; etoile <= 5; etoile++)
                    IconButton(
                      onPressed: () => onNoter(etoile),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      icon: const Icon(
                        Icons.star_border_rounded,
                        size: 25,
                        color: TovoTheme.inkDoux,
                      ),
                    ),
                ],
              ),
            ],
          );
  }
}

/// Le livreur, et un vrai bouton pour l'appeler.
///
/// Une petite icône de téléphone en bout de ligne passait inaperçue : c'est
/// pourtant LE geste attendu une fois le livreur connu.
class _BlocLivreur extends StatelessWidget {
  const _BlocLivreur({
    required this.prenom,
    required this.positionRecue,
    required this.onAppeler,
    this.onVoirLaCarte,
  });

  final String prenom;
  final bool positionRecue;
  final VoidCallback onAppeler;

  /// Dans le fil seulement : ouvre la feuille avec la grande carte.
  final VoidCallback? onVoirLaCarte;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // La carte, au-dessus, montre déjà la moto : la ligne ne sert que
        // tant qu'aucune position n'est arrivée.
        if (!positionRecue) ...[
          Row(
            children: [
              const Icon(
                Icons.two_wheeler_outlined,
                size: 20,
                color: TovoTheme.inkDoux,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Position du livreur en attente',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: TovoTheme.inkDoux,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        FilledButton.icon(
          onPressed: onAppeler,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.call, size: 19),
          label: Text(
            prenom.isEmpty ? 'Appeler le livreur' : 'Appeler $prenom',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        if (onVoirLaCarte != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onVoirLaCarte,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: TovoTheme.ink,
              side: const BorderSide(color: TovoTheme.line),
            ),
            icon: const Icon(Icons.map_outlined, size: 19),
            label: const Text(
              'Suivre sur la carte',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ],
    );
  }
}

/// Le paiement Nita, en une ligne, sans jargon.
///
/// Payé : « Payé par Nita ✓ ». Sinon : « Pas encore payé ? Envoyez 3 500 F à
/// Moussa, votre livreur » et son numéro, à copier d'un geste — comme on
/// lui tendrait des espèces. Pas de « code », pas de relance (retour du
/// client, 26/09) : la ligne disparaît d'elle-même une fois le paiement
/// constaté, par MyNita ou par le livreur.
class _PaiementNita extends StatelessWidget {
  const _PaiementNita({
    required this.paye,
    required this.montant,
    required this.prenom,
    required this.telephone,
  });

  final bool paye;
  final int montant;
  final String prenom;
  final String telephone;

  @override
  Widget build(BuildContext context) {
    if (paye) {
      return const Row(
        children: [
          LogoNita(taille: 18),
          SizedBox(width: 8),
          Text(
            'Payé par Nita',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: TovoTheme.ink,
            ),
          ),
          SizedBox(width: 6),
          Icon(Icons.check_rounded, size: 18, color: TovoTheme.success),
        ],
      );
    }
    final local =
        NumeroNita.nigerien(telephone) ??
        telephone.replaceAll(RegExp(r'\D'), '');
    final qui = prenom.isEmpty ? 'votre livreur' : '$prenom, votre livreur';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const LogoNita(taille: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: 'Pas encore payé ? Envoyez ',
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: TovoTheme.inkDoux,
                ),
                children: [
                  TextSpan(
                    text: montant > 0 ? Money.format(montant) : 'le montant',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: TovoTheme.ink,
                    ),
                  ),
                  TextSpan(text: ' à $qui'),
                  if (local.length == 8) ...[
                    const TextSpan(text: ' · '),
                    TextSpan(
                      text: NumeroNita.lisible(local),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: TovoTheme.ink,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (local.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: local));
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(
                    content: Text('Numéro copié'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              style: TextButton.styleFrom(
                foregroundColor: TovoTheme.ink,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
              ),
              child: const Text(
                'Copier',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
