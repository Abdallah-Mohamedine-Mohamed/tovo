import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../registry.dart';
import 'order_tracking.dart';

/// L'écran de suivi : la carte, plein écran, et rien d'autre (maquette
/// « Suivi Commande », 27/09).
///
/// Il monte du bas comme une feuille, mais couvre tout l'écran : une carte
/// posée par-dessus l'accueil laissait voir l'accueil au travers tant que
/// les tuiles n'étaient pas chargées. Un bouton retour, en haut à gauche.
Future<void> ouvrirSuivi(
  BuildContext context, {
  required TovoComponent component,
  required InteractionCallback onInteraction,
}) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (ecran, _, _) => AnnotatedRegion<SystemUiOverlayStyle>(
      // Barre d'état claire sur la carte de nuit, sombre sur celle de jour :
      // la carte la recouvre, c'est à elle d'en décider — en attendant, la
      // plus lisible sur les deux fonds.
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1D2D),
        body: OrderTracking(
          component: component,
          grandFormat: true,
          onInteraction: onInteraction,
          onFermer: () => Navigator.of(ecran).pop(),
        ),
      ),
    ),
    transitionsBuilder: (_, animation, _, enfant) {
      final courbe = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(courbe),
        child: enfant,
      );
    },
  ),
);

/// Depuis l'accueil : on n'a que l'identifiant de la commande. On lit son
/// état complet (la même fonction que le serveur, order_tracking), puis on
/// ouvre l'écran. Sans réseau, rien ne s'ouvre — mieux qu'un écran vide.
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
