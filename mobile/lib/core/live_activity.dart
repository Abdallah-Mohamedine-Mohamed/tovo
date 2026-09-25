import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'push.dart';

class TovoLiveActivity {
  TovoLiveActivity._();

  static const _methods = MethodChannel('tovo/live_activity');
  static const _tokens = EventChannel('tovo/live_activity_tokens');
  static final _registered = <String>{};
  static final _activityTokens = <String, String>{};

  /// Dernier prénom de livreur connu, par commande : une resynchronisation
  /// sans prénom ne doit pas l'effacer de l'île.
  static final _livreurs = <String, String>{};
  static StreamSubscription<dynamic>? _subscription;
  static StreamSubscription<AuthState>? _authSubscription;
  static StreamSubscription<String>? _fcmSubscription;

  static Future<void> start({
    required String orderId,
    required String status,
    required bool courier,
    required String title,
    DateTime? placedAt,
    String? mode,
    String? driver,
  }) async {
    if (!Platform.isIOS || orderId.isEmpty) return;
    _subscription ??= _tokens.receiveBroadcastStream().listen(
      (event) => unawaited(_registerToken(event)),
      onError: (Object error) => debugPrint('[live activity] $error'),
    );
    _authSubscription ??= Supabase.instance.client.auth.onAuthStateChange
        .listen((event) {
          if (event.event != AuthChangeEvent.signedOut) return;
          _registered.clear();
          _activityTokens.clear();
          unawaited(_endAll());
        });
    try {
      await _methods.invokeMethod<bool>('start', {
        'orderId': orderId,
        'status': status,
        'kind': courier ? 'courier' : 'food',
        'title': title,
        // Le temps écoulé (« Depuis 6:12 ») part de là et tourne tout seul.
        // Plus de compte à rebours forfaitaire (18/35 min) : l'heure
        // d'arrivée vient du serveur, sur les vraies distances, dès qu'un
        // livreur est en route (décision du client, 25/09).
        if (placedAt != null)
          'placedAt': placedAt.millisecondsSinceEpoch / 1000,
        'mode': ?mode,
        'driver': ?_prenom(driver),
      });
    } on PlatformException catch (error) {
      debugPrint('[live activity] ${error.message}');
    }
  }

  /// Le prénom seul : « Moussa vous l'apporte » tient dans l'île.
  static String? _prenom(String? nom) {
    final t = nom?.trim() ?? '';
    return t.isEmpty ? null : t.split(RegExp(r'\s+')).first;
  }

  static Future<void> sync(
    String orderId,
    String status, {
    String? driver,
  }) async {
    if (!Platform.isIOS || orderId.isEmpty) return;
    final prenom = _prenom(driver) ?? _livreurs[orderId];
    if (prenom != null) _livreurs[orderId] = prenom;
    final finished = const {'delivered', 'cancelled'}.contains(status);
    if (finished) {
      final token = _activityTokens.remove(orderId);
      if (token != null) _registered.remove('$orderId:$token');
    }
    try {
      await _methods.invokeMethod<bool>(finished ? 'end' : 'sync', {
        'orderId': orderId,
        'status': status,
        'driver': ?prenom,
      });
    } on PlatformException catch (error) {
      debugPrint('[live activity] ${error.message}');
    }
  }

  static Future<void> _endAll() async {
    try {
      await _methods.invokeMethod<bool>('endAll');
    } on PlatformException catch (error) {
      debugPrint('[live activity] ${error.message}');
    }
  }

  static Future<void> _registerToken(dynamic event) async {
    if (event is! Map) return;
    final orderId = event['orderId'];
    final activityToken = event['token'];
    if (orderId is! String || activityToken is! String) return;
    _activityTokens[orderId] = activityToken;
    final registration = '$orderId:$activityToken';
    if (!_registered.add(registration)) return;
    try {
      await TovoPush.initialiser();
      _fcmSubscription ??= FirebaseMessaging.instance.onTokenRefresh.listen((
        _,
      ) {
        _registered.clear();
        for (final entry in _activityTokens.entries) {
          unawaited(
            _registerToken({'orderId': entry.key, 'token': entry.value}),
          );
        }
      });
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          final fcmToken = await FirebaseMessaging.instance.getToken();
          if (fcmToken == null) throw StateError('FCM indisponible');
          await Supabase.instance.client.rpc(
            'register_push_token',
            params: {
              'p_token': fcmToken,
              'p_platform': 'ios',
              'p_app': 'client',
            },
          );
          final response = await TovoApi().post(
            '/orders/$orderId/live-activity',
            {'activity_token': activityToken, 'fcm_token': fcmToken},
          );
          if (!response.ok) throw StateError(response.content);
          await sync(orderId, response.raw['status'] as String? ?? 'pending');
          return;
        } on Exception {
          if (attempt == 3) rethrow;
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
    } on Exception catch (error) {
      _registered.remove(registration);
      debugPrint('[live activity] $error');
    }
  }
}
