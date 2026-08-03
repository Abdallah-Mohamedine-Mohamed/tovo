import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';

/// File de synchronisation hors ligne.
///
/// À Niamey, le réseau coupe. Un livreur qui confirme une livraison dans une
/// cour sans couverture ne doit pas voir son geste perdu, ni avoir à le
/// refaire en sortant. Toute action est donc écrite localement d'abord, puis
/// rejouée quand la connexion revient.
///
/// Trois propriétés non négociables :
///
/// ORDRE. Les actions se rejouent dans l'ordre où elles ont été faites. Une
/// livraison confirmée avant une récupération n'aurait aucun sens, et le
/// serveur la refuserait.
///
/// PERSISTANCE. La file survit à la fermeture de l'app et au redémarrage du
/// téléphone. Une file en mémoire ne protège que des micro-coupures, c'est-
/// à-dire du cas le moins gênant.
///
/// HONNÊTETÉ. Une action refusée par le serveur — course déjà prise par un
/// autre — est retirée de la file et signalée, jamais réessayée en boucle.
/// Le livreur doit apprendre que la course lui a échappé, pas voir un
/// indicateur tourner indéfiniment.
class SyncQueue {
  SyncQueue({required TovoApi api, SharedPreferences? prefs})
      : _api = api,
        _prefs = prefs;

  static const String _cle = 'tovo.driver.sync_queue.v1';

  final TovoApi _api;
  SharedPreferences? _prefs;

  final Queue<SyncAction> _actions = Queue<SyncAction>();

  /// Synchronisation en vol, s'il y en a une.
  ///
  /// `flush()` renvoie cette même instance plutôt que de rendre la main
  /// aussitôt : attendre `flush()` doit signifier « la file a été traitée »,
  /// sinon ni un test ni un « tirer pour rafraîchir » ne peuvent savoir
  /// quand l'opération est finie.
  Future<void>? _enVol;

  /// Actions rejetées définitivement, à montrer au livreur.
  final List<SyncFailure> rejets = [];

  /// Nombre d'actions en attente — alimente l'indicateur « n en attente ».
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final brut = _prefs!.getStringList(_cle) ?? const [];
    _actions
      ..clear()
      ..addAll(brut.map(SyncAction.decode).whereType<SyncAction>());
    pending.value = _actions.length;
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setStringList(
      _cle,
      _actions.map((a) => a.encode()).toList(growable: false),
    );
    pending.value = _actions.length;
  }

  /// Empile une action et tente de la synchroniser tout de suite.
  ///
  /// L'appelant n'attend pas le réseau : l'interface se met à jour
  /// immédiatement, la file se débrouille ensuite.
  Future<void> submit(SyncAction action) async {
    _actions.addLast(action);
    await _persist();
    unawaited(flush());
  }

  /// Rejoue la file, dans l'ordre, en s'arrêtant à la première coupure.
  ///
  /// Appelée pendant qu'une synchronisation tourne déjà, renvoie celle-ci :
  /// deux boucles concurrentes sur la même file rejoueraient des actions en
  /// double.
  Future<void> flush() {
    final enVol = _enVol;
    if (enVol != null) return enVol;

    final future = _traiter().whenComplete(() => _enVol = null);
    _enVol = future;
    return future;
  }

  Future<void> _traiter() async {
    {
      while (_actions.isNotEmpty) {
        final action = _actions.first;
        final reponse = await action.execute(_api);

        if (reponse.ok) {
          _actions.removeFirst();
          await _persist();
          continue;
        }

        if (reponse.isOffline) {
          // Toujours hors ligne : on garde la file intacte et on réessaiera.
          // Surtout, on ne passe pas à l'action suivante — l'ordre doit
          // être préservé.
          break;
        }

        // Refus du serveur : réessayer ne changera rien. On retire l'action
        // et on remonte l'explication.
        _actions.removeFirst();
        rejets.add(SyncFailure(action: action, message: reponse.content));
        await _persist();
      }
    }
  }

  void clearRejets() => rejets.clear();

  void dispose() => pending.dispose();
}

/// Une action rejouable. Sérialisable, puisqu'elle doit survivre à la
/// fermeture de l'app.
@immutable
class SyncAction {
  const SyncAction({
    required this.kind,
    required this.path,
    this.body = const {},
    required this.createdAt,
  });

  /// Libellé lisible, pour dire au livreur ce qui n'est pas encore parti.
  final SyncKind kind;
  final String path;
  final Map<String, dynamic> body;
  final DateTime createdAt;

  factory SyncAction.accept(String orderId) => SyncAction(
        kind: SyncKind.accept,
        path: '/orders/$orderId/accept',
        createdAt: DateTime.now(),
      );

  /// Preuve de livraison : le fichier reste local jusqu’à son envoi.
  factory SyncAction.proof(String orderId, String localPath) => SyncAction(
        kind: SyncKind.proof,
        path: '/orders/$orderId/proof',
        body: {'order_id': orderId, 'local_path': localPath},
        createdAt: DateTime.now(),
      );

  factory SyncAction.status(String orderId, String status) => SyncAction(
        kind: SyncKind.status,
        path: '/orders/$orderId/status',
        body: {'status': status},
        createdAt: DateTime.now(),
      );

  Future<TovoResponse> execute(TovoApi api) async {
    if (kind != SyncKind.proof) return api.post(path, body);

    // La preuve de livraison est un FICHIER, pas du JSON. On le garde sur
    // le téléphone et on le téléverse au retour du réseau — sans quoi un
    // livreur dans une cour sans couverture devrait reprendre la photo,
    // ou pire, livrer sans preuve.
    final chemin = body['local_path'] as String?;
    final orderId = body['order_id'] as String?;
    if (chemin == null || orderId == null) {
      return TovoResponse.failure(
        message: 'preuve incomplète',
        statusCode: 400,
        components: const [],
      );
    }

    final fichier = File(chemin);
    if (!fichier.existsSync()) {
      // Android a nettoyé son cache avant qu'on ait pu envoyer. On
      // abandonne la preuve plutôt que de bloquer la file : la livraison,
      // elle, a déjà été confirmée par une action distincte.
      return TovoResponse.success(content: 'preuve introuvable', components: const []);
    }

    try {
      final distant = '$orderId/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await Supabase.instance.client.storage.from('proofs').uploadBinary(
        distant,
        await fichier.readAsBytes(),
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );
      await Supabase.instance.client
          .from('orders')
          .update({'proof_photo_path': distant})
          .eq('id', orderId);

      await fichier.delete().catchError((_) => fichier);
      return TovoResponse.success(content: 'preuve envoyée', components: const []);
    } on Exception {
      return TovoResponse.failure(
        message: 'réseau indisponible',
        statusCode: 0,
        components: const [],
      );
    }
  }

  String encode() => jsonEncode({
        'kind': kind.name,
        'path': path,
        'body': body,
        'at': createdAt.toIso8601String(),
      });

  static SyncAction? decode(String brut) {
    try {
      final json = jsonDecode(brut) as Map<String, dynamic>;
      return SyncAction(
        kind: SyncKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => SyncKind.status,
        ),
        path: json['path'] as String,
        body: (json['body'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      );
    } catch (_) {
      // Une entrée corrompue est ignorée plutôt que de bloquer toute la
      // file : perdre une action vaut mieux que n'en rejouer aucune.
      return null;
    }
  }

  String get label => switch (kind) {
        SyncKind.accept => 'Acceptation de course',
        SyncKind.status => 'Changement de statut',
        SyncKind.proof => 'Photo de livraison',
      };
}

enum SyncKind { accept, status, proof }

@immutable
class SyncFailure {
  const SyncFailure({required this.action, required this.message});

  final SyncAction action;
  final String message;
}

/// Évite d'avoir à importer dart:async pour un seul usage.
void unawaited(Future<void> future) {
  future.catchError((_) {});
}
