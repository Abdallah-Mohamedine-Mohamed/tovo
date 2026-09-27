import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../registry.dart';
import 'order_tracking.dart';

/// La feuille de suivi : la carte, et rien d'autre.
///
/// Même allure que la fiche produit (product_sheet.dart) — posée au-dessus
/// de l'app, bords arrondis — mais presque tout l'écran, pour la carte.
/// La carte garde pour elle les gestes du doigt (zoom, glisser) : on ferme
/// par la croix.
Future<void> ouvrirSuivi(
  BuildContext context, {
  required TovoComponent component,
  required InteractionCallback onInteraction,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  enableDrag: false,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black54,
  builder: (feuille) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        height: MediaQuery.sizeOf(feuille).height * 0.9,
        child: Stack(
          children: [
            Positioned.fill(
              child: OrderTracking(
                component: component,
                grandFormat: true,
                onInteraction: onInteraction,
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: Material(
                color: const Color(0xF2121A26),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.pop(feuille),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// Depuis l'accueil : on n'a que l'identifiant de la commande. On lit son
/// état complet (la même fonction que le serveur, order_tracking), puis on
/// ouvre la feuille. Sans réseau, rien ne s'ouvre — mieux qu'une feuille
/// vide.
Future<void> ouvrirSuiviCommande(
  BuildContext context, {
  required String orderId,
  required InteractionCallback onInteraction,
}) async {
  final etat = await Supabase.instance.client.rpc(
    'order_tracking',
    params: {'p_order_id': orderId},
  );
  if (!context.mounted || etat is! Map) return;
  await ouvrirSuivi(
    context,
    component: TovoComponent(
      type: 'order_tracking',
      data: etat.cast<String, dynamic>(),
    ),
    onInteraction: onInteraction,
  );
}
