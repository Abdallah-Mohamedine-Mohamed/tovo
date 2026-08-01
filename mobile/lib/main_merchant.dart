import 'package:flutter/material.dart';

import 'core/theme.dart';

/// Point d'entrée de l'app BOUTIQUIER — nouvelle fiche store,
/// identifiant `com.unique.tovo.merchant`.
///
/// Phase 6 : gestion du catalogue (produits, options, images, disponibilité)
/// et réception des commandes entrantes en temps réel via Supabase Realtime.
void main() {
  runApp(const TovoMerchantApp());
}

class TovoMerchantApp extends StatelessWidget {
  const TovoMerchantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tovo Boutique',
      debugShowCheckedModeBanner: false,
      theme: TovoTheme.build(),
      home: const Scaffold(
        body: Center(child: Text('Tovo Boutique — Phase 6')),
      ),
    );
  }
}
