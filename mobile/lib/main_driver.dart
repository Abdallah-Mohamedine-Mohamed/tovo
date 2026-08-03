import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'core/push.dart';
import 'core/theme.dart';
import 'features/auth/auth_gate.dart';
import 'features/driver/driver_home.dart';

/// Point d'entrée de l'app LIVREUR — `com.tovo.delivery`.
///
/// Offline-first : toute action est écrite localement avant d'être envoyée,
/// et rejouée dans l'ordre au retour du réseau. Voir
/// features/driver/sync_queue.dart.
///
/// flutter run --flavor driver -t lib/main_driver.dart \
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
      home: AuthGate(
        appPush: 'driver',
        titre: 'Tovo Livreur',
        sousTitre: 'Recevez des courses et suivez vos gains.',
        roleRequis: 'driver',
        child: () => DriverHome(api: TovoApi()),
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
