import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Notifications push.
///
/// Trois apps partagent ce fichier, avec un jeton par app : un livreur qui
/// est aussi client le soir doit recevoir ses courses d'un côté et ses
/// commandes de l'autre, sans mélange.
///
/// L'enregistrement se fait APRÈS la connexion, jamais avant : un jeton sans
/// utilisateur n'a personne à qui être rattaché.
class TovoPush {
  const TovoPush._();

  static bool _initialise = false;

  /// À appeler au démarrage, avant `runApp`.
  ///
  /// Un échec ici ne doit pas empêcher l'app de démarrer : mieux vaut une
  /// app sans notifications qu'une app qui ne s'ouvre pas.
  static Future<void> initialiser() async {
    if (_initialise) return;
    try {
      await Firebase.initializeApp();
      _initialise = true;
    } on Exception catch (cause) {
      debugPrint('[push] Firebase indisponible : $cause');
    }
  }

  /// Demande l'autorisation, récupère le jeton et l'enregistre.
  ///
  /// [app] vaut `client`, `driver` ou `merchant`.
  static Future<void> enregistrer(String app) async {
    if (!_initialise) return;
    if (Supabase.instance.client.auth.currentUser == null) return;

    try {
      final messaging = FirebaseMessaging.instance;

      // Sur iOS et Android 13+, l'autorisation est explicite. Un refus n'est
      // pas une erreur : l'utilisateur a le droit de ne pas vouloir être
      // interrompu, et le reste de l'app continue de fonctionner.
      final permission = await messaging.requestPermission();
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[push] notifications refusées par l’utilisateur');
        return;
      }

      final jeton = await messaging.getToken();
      if (jeton == null) return;

      await _envoyer(jeton, app);

      // FCM régénère le jeton après une réinstallation ou un effacement des
      // données. Sans cette écoute, l'utilisateur cesserait silencieusement
      // de recevoir quoi que ce soit.
      messaging.onTokenRefresh.listen((nouveau) => _envoyer(nouveau, app));
    } on Exception catch (cause) {
      debugPrint('[push] enregistrement impossible : $cause');
    }
  }

  static Future<void> _envoyer(String jeton, String app) async {
    try {
      await Supabase.instance.client.rpc('register_push_token', params: {
        'p_token': jeton,
        'p_platform': Platform.isIOS ? 'ios' : 'android',
        'p_app': app,
      });
    } on Exception catch (cause) {
      debugPrint('[push] jeton non enregistré : $cause');
    }
  }

  /// Notifications reçues pendant que l'app est ouverte.
  ///
  /// Android ne les affiche pas dans ce cas : c'est à l'app de réagir. On
  /// remonte la charge utile pour que l'écran concerné se rafraîchisse — un
  /// boutiquier dont l'app est ouverte doit voir la commande apparaître,
  /// pas une bannière qu'il devra toucher.
  static Stream<Map<String, String>> messagesEnAvantPlan() {
    if (!_initialise) return const Stream.empty();
    return FirebaseMessaging.onMessage.map(
      (message) => {
        ...message.data.map((k, v) => MapEntry(k, '$v')),
        if (message.notification?.title != null) 'title': message.notification!.title!,
        if (message.notification?.body != null) 'body': message.notification!.body!,
      },
    );
  }

  /// Notification touchée alors que l'app était fermée ou en arrière-plan.
  static Future<Map<String, String>?> messageDOuverture() async {
    if (!_initialise) return null;
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial == null) return null;
    return initial.data.map((k, v) => MapEntry(k, '$v'));
  }
}
