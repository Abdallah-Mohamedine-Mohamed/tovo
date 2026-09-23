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
  static Future<void>? _initialisation;
  static final Set<String> _enregistres = {};

  static Future<void> initialiser() {
    if (_initialise) return Future.value();
    return _initialisation ??= _demarrer().whenComplete(() {
      if (!_initialise) _initialisation = null;
    });
  }

  static Future<void> _demarrer() async {
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
    await initialiser();
    if (!_initialise) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final key = '$app:$userId';
    if (_enregistres.contains(key)) return;

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

      if (await _envoyer(jeton, app)) _enregistres.add(key);

      // FCM régénère le jeton après une réinstallation ou un effacement des
      // données. Sans cette écoute, l'utilisateur cesserait silencieusement
      // de recevoir quoi que ce soit.
      messaging.onTokenRefresh.listen((nouveau) => _envoyer(nouveau, app));
    } on Exception catch (cause) {
      debugPrint('[push] enregistrement impossible : $cause');
    }
  }

  /// Détache l'appareil du compte, à appeler AVANT `signOut`.
  ///
  /// Le jeton FCM appartient au téléphone, pas à la personne. Sans cet oubli,
  /// le boutiquier qui se déconnecte continuerait de recevoir les commandes
  /// de sa boutique — y compris sur un téléphone prêté ou revendu. La RLS
  /// n'autorise à supprimer que ses propres jetons : d'où l'ordre, session
  /// encore ouverte.
  static Future<void> oublier() async {
    _enregistres.clear();
    await initialiser();
    if (!_initialise) return;
    try {
      final jeton = await FirebaseMessaging.instance.getToken();
      if (jeton == null) return;
      await Supabase.instance.client
          .from('push_tokens')
          .delete()
          .eq('token', jeton);
    } on Exception catch (cause) {
      // Un échec ici ne doit pas empêcher de se déconnecter : rester
      // connecté contre son gré est pire que recevoir une notification de
      // trop, que la purge côté serveur finira par éliminer.
      debugPrint('[push] jeton non oublié : $cause');
    }
  }

  static Future<bool> _envoyer(String jeton, String app) async {
    try {
      await Supabase.instance.client.rpc(
        'register_push_token',
        params: {
          'p_token': jeton,
          'p_platform': Platform.isIOS ? 'ios' : 'android',
          'p_app': app,
        },
      );
      return true;
    } on Exception catch (cause) {
      debugPrint('[push] jeton non enregistré : $cause');
      return false;
    }
  }

  /// Notifications reçues pendant que l'app est ouverte.
  ///
  /// Android ne les affiche pas dans ce cas : c'est à l'app de réagir. On
  /// remonte la charge utile pour que l'écran concerné se rafraîchisse — un
  /// boutiquier dont l'app est ouverte doit voir la commande apparaître,
  /// pas une bannière qu'il devra toucher.
  static Stream<Map<String, String>> messagesEnAvantPlan() async* {
    await initialiser();
    if (!_initialise) return;
    yield* FirebaseMessaging.onMessage.map(
      (message) => {
        ...message.data.map((k, v) => MapEntry(k, '$v')),
        if (message.notification?.title != null)
          'title': message.notification!.title!,
        if (message.notification?.body != null)
          'body': message.notification!.body!,
      },
    );
  }

  /// Notification touchée alors que l'app était fermée ou en arrière-plan.
  static Future<Map<String, String>?> messageDOuverture() async {
    await initialiser();
    if (!_initialise) return null;
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial == null) return null;
    return initial.data.map((k, v) => MapEntry(k, '$v'));
  }
}
