import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'components/register_all.dart';
import 'core/api.dart';
import 'core/config.dart';
import 'core/location.dart';
import 'core/push.dart';
import 'core/read_cache.dart';
import 'core/suivi_commande.dart';
import 'core/theme.dart';
import 'features/auth/auth_gate.dart';
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
/// Android, app fermée ou en arrière-plan : le serveur envoie chaque étape
/// de la commande en message silencieux, et c'est ICI que la notification
/// de suivi se met à jour — sur place, sans en empiler une nouvelle.
@pragma('vm:entry-point')
Future<void> _suiviEnArrierePlan(RemoteMessage message) async {
  await Firebase.initializeApp();
  await SuiviAndroid.afficher(message.data);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  registerTovoComponents();
  if (Platform.isAndroid) {
    FirebaseMessaging.onBackgroundMessage(_suiviEnArrierePlan);
  }

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
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      TovoPush.initialiser().then((_) {
        // App ouverte : le même suivi, mis à jour à la réception.
        if (Platform.isAndroid && Firebase.apps.isNotEmpty) {
          FirebaseMessaging.onMessage.listen(
            (message) => unawaited(SuiviAndroid.afficher(message.data)),
          );
        }
      }),
    );
    // Sans fenêtre d'autorisation : seulement si elle est déjà accordée.
    TovoLocation.prechauffer();
  });
}

class TovoClientApp extends StatelessWidget {
  const TovoClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tovo',
      debugShowCheckedModeBanner: false,
      theme: TovoTheme.client(),
      home: AuthGate(
        appPush: 'client',
        titre: 'Tovo',
        sousTitre:
            'Connectez-vous avec votre numéro pour retrouver vos commandes et suivre vos livraisons.',
        child: () => ChatScreen(
          api: TovoApi(
            cache: TovoReadCache(Supabase.instance.client.auth.currentUser!.id),
          ),
        ),
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
      theme: TovoTheme.client(),
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
