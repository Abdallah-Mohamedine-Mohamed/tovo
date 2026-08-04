import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../registry.dart';

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

class _OrderTrackingState extends State<OrderTracking> {
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
    _abonner();
  }

  @override
  void dispose() {
    _desabonner();
    super.dispose();
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
    final etapes = (widget.component.data['steps'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final courante = etapes.indexOf(_statut);
    final annulee = _statut == 'cancelled';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x12000000)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            color: annulee ? const Color(0xFFFDECEA) : TovoTheme.tealSoft,
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: annulee ? TovoTheme.danger : TovoTheme.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _libelles[_statut] ?? _statut,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: annulee ? TovoTheme.danger : TovoTheme.teal,
                    ),
                  ),
                ),
                Text(
                  Money.format(widget.component.money('total')),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: TovoTheme.ink,
                  ),
                ),
              ],
            ),
          ),
          if (!annulee && etapes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: Row(
                children: [
                  for (var i = 0; i < etapes.length; i++) ...[
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: i <= courante ? TovoTheme.teal : TovoTheme.line,
                        shape: BoxShape.circle,
                      ),
                    ),
                    if (i < etapes.length - 1)
                      Expanded(
                        child: Container(
                          height: 2,
                          color: i < courante ? TovoTheme.teal : TovoTheme.line,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          if (_livreur != null) _BlocLivreur(
            livreur: _livreur!,
            positionRecue: _dernierePosition != null,
            onAppeler: () => widget.onInteraction(
              TovoInteraction('call_driver', {'phone': _livreur!['phone'] ?? ''}),
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
                const Icon(Icons.favorite_rounded, size: 16, color: TovoTheme.teal),
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
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
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
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                Text(
                  // La carte viendra avec l'intégration cartographique. En
                  // attendant, dire simplement si la position arrive vaut
                  // mieux qu'un cadre vide.
                  positionRecue ? 'Position mise à jour' : 'En attente de position',
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
