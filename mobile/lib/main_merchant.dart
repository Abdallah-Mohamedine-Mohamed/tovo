import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'core/push.dart';
import 'core/theme.dart';
import 'features/auth/auth_gate.dart';
import 'features/merchant/merchant_home.dart';

/// Point d'entrée de l'app BOUTIQUIER — `com.tovo.store`.
///
/// Les commandes entrantes arrivent par Supabase Realtime : le boutiquier a
/// les mains occupées, il ne doit pas avoir à rafraîchir un écran.
///
/// flutter run --flavor merchant -t lib/main_merchant.dart \
///   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... \
///   --dart-define=API_BASE_URL=...
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Un échec ici ne doit pas empêcher l'app de démarrer : mieux vaut une
  // app sans notifications qu'une app qui ne s'ouvre pas.
  await TovoPush.initialiser();

  if (!TovoConfig.isConfigured) {
    runApp(const _EcranDeConfiguration());
    return;
  }

  await Supabase.initialize(
    url: TovoConfig.supabaseUrl,
    publishableKey: TovoConfig.supabaseAnonKey,
  );

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
      home: AuthGate(
        appPush: 'merchant',
        titre: 'Tovo Boutique',
        sousTitre: 'Gérez vos commandes et votre catalogue.',
        roleRequis: 'merchant',
        child: () => MerchantHome(api: TovoApi()),
      ),
    );
  }
}

class _EcranDeConfiguration extends StatelessWidget {
  const _EcranDeConfiguration();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TovoTheme.build(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              TovoConfig.configurationError,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: TovoTheme.muted),
            ),
          ),
        ),
      ),
    );
  }
}
