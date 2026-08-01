import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'components/register_all.dart';
import 'core/api.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'features/chat/chat_screen.dart';

/// Point d'entrée de l'app CLIENT.
///
/// Identifiants publiés — ne pas changer :
///   Android  com.unique.tovo.user
///   iOS      com.tovoapp.UserApp
///
/// flutter run --flavor client -t lib/main_client.dart \
///   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... \
///   --dart-define=API_BASE_URL=...
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  registerTovoComponents();

  if (!TovoConfig.isConfigured) {
    // Un écran d'erreur lisible plutôt qu'un plantage au premier appel
    // réseau : c'est l'oubli de configuration le plus courant.
    runApp(const _EcranDeConfiguration());
    return;
  }

  await Supabase.initialize(
    url: TovoConfig.supabaseUrl,
    // `publishableKey` et non `anonKey` : ce dernier est déprécié depuis que
    // Supabase a remplacé les clés JWT historiques par des clés opaques.
    publishableKey: TovoConfig.supabaseAnonKey,
  );

  runApp(const TovoClientApp());
}

class TovoClientApp extends StatelessWidget {
  const TovoClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tovo',
      debugShowCheckedModeBanner: false,
      theme: TovoTheme.build(),
      home: ChatScreen(api: TovoApi()),
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
