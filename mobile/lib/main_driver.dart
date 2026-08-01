import 'package:flutter/material.dart';

import 'core/theme.dart';

/// Point d'entrée de l'app LIVREUR — nouvelle fiche store,
/// identifiant `com.unique.tovo.driver`.
///
/// Phase 5 : file de synchronisation Isar, position adaptative, solde du
/// jour. L'offline-first n'est pas une option ici, c'est la contrainte
/// première.
void main() {
  runApp(const TovoDriverApp());
}

class TovoDriverApp extends StatelessWidget {
  const TovoDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tovo Livreur',
      debugShowCheckedModeBanner: false,
      theme: TovoTheme.build(),
      home: const Scaffold(
        body: Center(child: Text('Tovo Livreur — Phase 5')),
      ),
    );
  }
}
