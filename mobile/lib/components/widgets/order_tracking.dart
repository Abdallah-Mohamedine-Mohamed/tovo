import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../registry.dart';

const List<String> _etapesCommandeVisibles = [
  'Acceptée',
  'Prête',
  'En livraison',
  'Livrée',
];

const List<String> _etapesColisVisibles = [
  'Livreur trouvé',
  'Colis récupéré',
  'En livraison',
  'Livré',
];

int _etapeColisVisible(String statut) => switch (statut) {
  'assigned' => 0,
  'picked_up' => 1,
  'delivering' => 2,
  'delivered' => 3,
  _ => -1,
};

int _etapeCommandeVisible(String statut) {
  switch (statut) {
    case 'pending':
      return -1;
    case 'confirmed':
      return 0;
    case 'preparing':
    case 'ready':
    case 'assigned':
    case 'picked_up':
      return 1;
    case 'delivering':
      return 2;
    case 'delivered':
      return 3;
    default:
      return -1;
  }
}

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
  });

  final TovoComponent component;
  final InteractionCallback onInteraction;

  @override
  State<OrderTracking> createState() => _OrderTrackingState();
}

class _OrderTrackingState extends State<OrderTracking>
    with WidgetsBindingObserver {
  RealtimeChannel? _canalCommande;
  RealtimeChannel? _canalLivreur;

  late String _statut;
  Map<String, dynamic>? _livreur;
  DateTime? _dernierePosition;

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
    WidgetsBinding.instance.addObserver(this);
    _relire();
    _abonner();
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
    if (_orderId.isEmpty) return;

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
      });

      // Livrée pendant l'absence : plus rien à écouter, et l'abonnement
      // ouvert coûterait de la batterie pour un événement qui ne viendra pas.
      if (_termine.contains(statut)) _desabonner();
    } on Exception {
      // Réseau muet : la photo du message reste affichée, ce qui vaut mieux
      // qu'une carte vide. Le prochain retour au premier plan réessaiera.
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
            setState(() => _statut = nouveau);
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
          callback: (_) {
            if (!mounted) return;
            setState(() => _dernierePosition = DateTime.now());
          },
        )
        .subscribe();
  }

  void _desabonner() {
    final client = Supabase.instance.client;
    if (_canalCommande != null) client.removeChannel(_canalCommande!);
    if (_canalLivreur != null) client.removeChannel(_canalLivreur!);
    _canalCommande = null;
    _canalLivreur = null;
  }

  static const Map<String, String> _libelles = {
    'pending': 'En attente de confirmation',
    'confirmed': 'Commande confirmée',
    'preparing': 'En préparation',
    'ready': 'Prête, en attente d’un livreur',
    'assigned': 'Un livreur arrive',
    'picked_up': 'Commande récupérée',
    'delivering': 'En route vers vous',
    'delivered': 'Livrée',
    'cancelled': 'Annulée',
  };

  @override
  Widget build(BuildContext context) {
    final colis = widget.component.str('type', '') == 'courier';
    final etapes = colis ? _etapesColisVisibles : _etapesCommandeVisibles;
    final courante = colis
        ? _etapeColisVisible(_statut)
        : _etapeCommandeVisible(_statut);
    final annulee = _statut == 'cancelled';
    // Même règle que la base (cancel_my_order) : tant qu'aucun livreur
    // n'est parti. La base tranche de toute façon, ce bouton ne fait
    // qu'éviter de le proposer quand c'est perdu d'avance.
    final annulable =
        _livreur == null &&
        const {'pending', 'confirmed', 'preparing', 'ready'}.contains(_statut);
    final libelle = colis && (_statut == 'pending' || _statut == 'ready')
        ? 'On vous trouve un livreur'
        : _libelles[_statut] ?? _statut;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        boxShadow: TovoTheme.ombreFlottante,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'VOTRE COMMANDE',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        libelle,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: annulee ? TovoTheme.danger : TovoTheme.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  Money.format(widget.component.money('total')),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: TovoTheme.teal,
                  ),
                ),
              ],
            ),
          ),
          if (!annulee)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < etapes.length; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Row(
                            children: [
                              if (i > 0)
                                Expanded(
                                  child: AnimatedContainer(
                                    duration: TovoTheme.normal,
                                    height: 2,
                                    color: i <= courante
                                        ? TovoTheme.teal
                                        : TovoTheme.line,
                                  ),
                                ),
                              AnimatedContainer(
                                duration: TovoTheme.normal,
                                width: i == courante ? 22 : 18,
                                height: i == courante ? 22 : 18,
                                decoration: BoxDecoration(
                                  color: i <= courante
                                      ? TovoTheme.teal
                                      : TovoTheme.line,
                                  shape: BoxShape.circle,
                                ),
                                child: i <= courante
                                    ? const Icon(
                                        Icons.check,
                                        size: 12,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                              if (i < etapes.length - 1)
                                Expanded(
                                  child: AnimatedContainer(
                                    duration: TovoTheme.normal,
                                    height: 2,
                                    color: i < courante
                                        ? TovoTheme.teal
                                        : TovoTheme.line,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            etapes[i],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: i == courante
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: i <= courante
                                  ? TovoTheme.teal
                                  : TovoTheme.inkDoux,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (_livreur != null)
            _BlocLivreur(
              livreur: _livreur!,
              positionRecue: _dernierePosition != null,
              onAppeler: () => widget.onInteraction(
                TovoInteraction('call_driver', {
                  'phone': _livreur!['phone'] ?? '',
                }),
              ),
            ),
          if (annulable)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => widget.onInteraction(
                    TovoInteraction('cancel_order', {'order_id': _orderId}),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: TovoTheme.inkDoux,
                  ),
                  child: const Text('Annuler'),
                ),
              ),
            ),
          // La notation apparaît au moment où elle a du sens, dans la carte
          // que le client regarde déjà. Un écran séparé qu'il faudrait aller
          // ouvrir ne serait jamais visité, et les boutiques resteraient
          // toutes à 5,0 sans que personne ne l'ait décidé.
          if (_statut == 'delivered')
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
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.component.str('merchant_name'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: TovoTheme.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  (widget.component.map('dropoff')['hint'] as String?) ?? '',
                  style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: TovoTheme.surface,
        borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
      ),
      child: noteDeposee != null
          ? Row(
              children: [
                const Icon(
                  Icons.favorite_rounded,
                  size: 16,
                  color: TovoTheme.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Merci, votre note est enregistrée.',
                    style: const TextStyle(fontSize: 12, color: TovoTheme.ink),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Comment s’est passée cette commande ?',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
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
                          Icons.star_rounded,
                          size: 26,
                          color: TovoTheme.line,
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _BlocLivreur extends StatelessWidget {
  const _BlocLivreur({
    required this.livreur,
    required this.positionRecue,
    required this.onAppeler,
  });

  final Map<String, dynamic> livreur;
  final bool positionRecue;
  final VoidCallback onAppeler;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TovoTheme.surface,
        borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 18,
            backgroundColor: TovoTheme.teal,
            child: Icon(Icons.two_wheeler, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (livreur['name'] as String?) ?? 'Votre livreur',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  // La carte viendra avec l'intégration cartographique. En
                  // attendant, dire simplement si la position arrive vaut
                  // mieux qu'un cadre vide.
                  positionRecue
                      ? 'Position mise à jour'
                      : 'En attente de position',
                  style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onAppeler,
            icon: const Icon(Icons.phone, color: TovoTheme.teal, size: 20),
          ),
        ],
      ),
    );
  }
}
