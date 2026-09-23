import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../registry.dart';

const List<String> _etapesCommandeVisibles = [
  'Confirmée',
  'En préparation',
  'Prête',
  'Récupérée',
  'En route',
  'Livrée',
];

const List<String> _etapesColisVisibles = [
  'Recherche du livreur',
  'Livreur trouvé',
  'Colis récupéré',
  'En route',
  'Livré',
];

int _etapeColisVisible(String statut) => switch (statut) {
  'pending' || 'confirmed' || 'ready' => 0,
  'assigned' => 1,
  'picked_up' => 2,
  'delivering' => 3,
  'delivered' => 4,
  _ => -1,
};

int _etapeCommandeVisible(String statut) {
  switch (statut) {
    case 'pending':
      return -1;
    case 'confirmed':
      return 0;
    case 'preparing':
      return 1;
    case 'ready':
    case 'assigned':
      return 2;
    case 'picked_up':
      return 3;
    case 'delivering':
      return 4;
    case 'delivered':
      return 5;
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
    if (_canalCommande == null && _canalLivreur == null) return;
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

  String _description(bool colis) {
    if (_statut == 'cancelled') return 'Cette commande ne sera pas livrée.';
    if (colis) {
      return switch (_statut) {
        'pending' || 'confirmed' || 'ready' =>
          'Nous cherchons un livreur pour prendre en charge votre colis.',
        'assigned' => 'Votre livreur va récupérer le colis.',
        'picked_up' => 'Le colis a été récupéré par votre livreur.',
        'delivering' => 'Votre colis est en chemin vers sa destination.',
        'delivered' => 'Votre colis est arrivé à destination.',
        _ => 'Suivez votre livraison ici.',
      };
    }
    return switch (_statut) {
      'pending' => 'La boutique doit encore confirmer votre commande.',
      'confirmed' => 'La boutique a accepté votre commande.',
      'preparing' => 'La boutique prépare votre commande.',
      'ready' => 'Votre commande attend qu’un livreur la récupère.',
      'assigned' => 'Un livreur se rend à la boutique.',
      'picked_up' => 'Le livreur a récupéré votre commande.',
      'delivering' => 'Votre commande est en chemin vers vous.',
      'delivered' => 'Votre commande vous a été remise.',
      _ => 'Suivez votre commande ici.',
    };
  }

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
    final libelle = colis
        ? switch (_statut) {
            'pending' || 'confirmed' || 'ready' => 'Recherche d’un livreur',
            'assigned' => 'Livreur trouvé',
            'picked_up' => 'Colis récupéré',
            'delivering' => 'Colis en route',
            'delivered' => 'Colis livré',
            'cancelled' => 'Livraison annulée',
            _ => _statut,
          }
        : _libelles[_statut] ?? _statut;

    final details = [
      if (widget.component.str('merchant_name').isNotEmpty)
        widget.component.str('merchant_name'),
      if (((widget.component.map('dropoff')['hint'] as String?) ?? '')
          .isNotEmpty)
        widget.component.map('dropoff')['hint'] as String,
      if (widget.component.money('total') > 0)
        Money.format(widget.component.money('total')),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
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
                    color: annulee ? TovoTheme.danger : TovoTheme.ink,
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
            const SizedBox(height: 28),
            for (var index = 0; index < etapes.length; index++)
              _EtapeSuivi(
                libelle: etapes[index],
                terminee: index < courante,
                active: index == courante,
                ligneTerminee: index < courante,
                derniere: index == etapes.length - 1,
              ),
          ],
          if (_livreur != null && !annulee) ...[
            const SizedBox(height: 18),
            _BlocLivreur(
              livreur: _livreur!,
              positionRecue: _dernierePosition != null,
              onAppeler: () => widget.onInteraction(
                TovoInteraction('call_driver', {
                  'phone': _livreur!['phone'] ?? '',
                }),
              ),
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
              style: TextButton.styleFrom(
                foregroundColor: TovoTheme.inkDoux,
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
  }
}

class _EtapeSuivi extends StatelessWidget {
  const _EtapeSuivi({
    required this.libelle,
    required this.terminee,
    required this.active,
    required this.ligneTerminee,
    required this.derniere,
  });

  final String libelle;
  final bool terminee;
  final bool active;
  final bool ligneTerminee;
  final bool derniere;

  @override
  Widget build(BuildContext context) {
    final couleur = active
        ? TovoTheme.teal
        : terminee
        ? TovoTheme.inkDoux
        : TovoTheme.muted;

    return SizedBox(
      height: derniere ? 30 : 46,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: TovoTheme.normal,
                  width: active ? 20 : 18,
                  height: active ? 20 : 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? TovoTheme.teal : Colors.transparent,
                    border: Border.all(
                      color: active || terminee
                          ? TovoTheme.teal
                          : TovoTheme.line,
                      width: active ? 0 : 1.5,
                    ),
                  ),
                  child: terminee
                      ? const Icon(Icons.check, size: 12, color: TovoTheme.teal)
                      : active
                      ? const Center(
                          child: SizedBox(
                            width: 5,
                            height: 5,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
                if (!derniere)
                  Expanded(
                    child: AnimatedContainer(
                      duration: TovoTheme.normal,
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: ligneTerminee ? TovoTheme.teal : TovoTheme.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                libelle,
                style: TextStyle(
                  fontSize: active ? 15 : 14,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: couleur,
                ),
              ),
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
    return Row(
      children: [
        const Icon(Icons.two_wheeler_outlined, size: 23, color: TovoTheme.ink),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (livreur['name'] as String?) ?? 'Votre livreur',
                style: const TextStyle(
                  fontSize: 14,
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
                style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onAppeler,
          tooltip: 'Appeler le livreur',
          icon: const Icon(Icons.call_outlined, color: TovoTheme.ink, size: 21),
        ),
      ],
    );
  }
}
