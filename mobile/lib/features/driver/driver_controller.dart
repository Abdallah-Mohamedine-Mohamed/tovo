import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import 'sync_queue.dart';

/// État de l'app livreur.
///
/// Un seul écran est actif à la fois, et c'est cet objet qui décide lequel :
/// pas de course → le pool ; une course acceptée → son détail. Le livreur
/// conduit une moto dans la circulation de Niamey, il ne doit jamais avoir à
/// choisir entre deux vues.
///
/// Toute action passe par la file de synchronisation. L'interface avance
/// immédiatement, sans attendre le réseau — et si le réseau manque, elle
/// avance quand même : c'est la promesse de l'offline-first.
class DriverController extends ChangeNotifier {
  DriverController({required TovoApi api, SyncQueue? queue})
      : _api = api,
        queue = queue ?? SyncQueue(api: api);

  final TovoApi _api;
  final SyncQueue queue;

  Timer? _ping;
  Timer? _rafraichissement;

  bool _online = false;
  bool get online => _online;

  bool chargement = false;
  String? erreur;

  /// Courses disponibles, quand aucune n'est en cours.
  List<Map<String, dynamic>> pool = const [];

  /// Course en cours, s'il y en a une.
  Map<String, dynamic>? course;

  /// Résumé de la journée : courses, gains, cash à reverser.
  Map<String, dynamic> resume = const {
    'courses': 0,
    'earned': 0,
    'cash_collected': 0,
    'cash_due': 0,
  };

  String? get courseId => course?['order_id'] as String?;
  String get statut => (course?['status'] as String?) ?? '';

  Future<void> start() async {
    await queue.load();
    await refresh();
    _programmerRafraichissement();
  }

  @override
  void dispose() {
    _ping?.cancel();
    _rafraichissement?.cancel();
    queue.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Disponibilité
  // ------------------------------------------------------------------

  Future<void> setOnline(bool valeur) async {
    _online = valeur;
    notifyListeners();
    _programmerPing();
    if (valeur) await refresh();
  }

  /// Cadence du ping de position.
  ///
  /// 10 s en course : c'est ce qui alimente la carte du client, et une
  /// position vieille d'une minute ne sert à rien pour suivre une moto.
  /// 60 s au repos : le dispatch a seulement besoin de savoir dans quel
  /// quartier se trouve le livreur.
  /// Rien hors ligne : la batterie et le forfait data d'un livreur sont des
  /// ressources qu'il paie lui-même.
  Duration get _cadencePing =>
      course != null ? const Duration(seconds: 10) : const Duration(seconds: 60);

  void _programmerPing() {
    _ping?.cancel();
    if (!_online) return;

    _ping = Timer.periodic(_cadencePing, (_) => _envoyerPosition());
    unawaited(_envoyerPosition());
  }

  Future<void> _envoyerPosition() async {
    if (!_online) return;

    final position = await TovoLocation.current();
    if (position == null) return;

    // Le ping n'entre PAS dans la file de synchronisation : une position
    // vieille de vingt minutes rejouée au retour du réseau serait fausse et
    // trompeuse. On la perd, c'est le bon comportement.
    await _api.post('/driver/location', {
      'lat': position.latitude,
      'lng': position.longitude,
      'order_id': courseId,
      'heading': position.heading,
      'speed_kmh': position.speed * 3.6,
    });
  }

  void _programmerRafraichissement() {
    _rafraichissement?.cancel();
    _rafraichissement = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refresh(silencieux: true),
    );
  }

  // ------------------------------------------------------------------
  // Chargement
  // ------------------------------------------------------------------

  Future<void> refresh({bool silencieux = false}) async {
    if (!silencieux) {
      chargement = true;
      erreur = null;
      notifyListeners();
    }

    // On rejoue d'abord ce qui attend : inutile d'afficher un pool obsolète
    // alors qu'une acceptation est encore en file.
    await queue.flush();

    final courses = await _api.get('/orders', query: {'limit': 5});
    final enCours = _trouverCourseActive(courses);

    if (enCours != null) {
      final suivi = await _api.get('/orders/$enCours');
      if (suivi.ok && suivi.components.isNotEmpty) {
        course = suivi.components.first.data;
      }
      pool = const [];
    } else {
      course = null;
      if (_online) {
        final reponse = await _api.get('/driver/pool');
        pool = reponse.ok ? _extraireOrdres(reponse) : const [];
      } else {
        pool = const [];
      }
    }

    final resumeReponse = await _api.get('/driver/summary');
    if (resumeReponse.ok && resumeReponse.raw.isNotEmpty) {
      resume = resumeReponse.raw;
    }

    chargement = false;
    _programmerPing();
    notifyListeners();
  }

  static const _statutsActifs = {'assigned', 'picked_up', 'delivering'};

  String? _trouverCourseActive(TovoResponse reponse) {
    if (!reponse.ok) return null;
    for (final ordre in _extraireOrdres(reponse)) {
      if (_statutsActifs.contains(ordre['status'])) return ordre['id'] as String?;
    }
    return null;
  }

  static List<Map<String, dynamic>> _extraireOrdres(TovoResponse reponse) =>
      reponse.list('orders');

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------

  /// Accepte une course.
  ///
  /// L'interface bascule immédiatement sur le détail, avant même la réponse
  /// du serveur. Si la course a été prise par un autre, la file remonte le
  /// refus et on revient au pool — mieux vaut une correction franche qu'un
  /// bouton qui ne réagit pas pendant dix secondes sur un réseau lent.
  Future<void> accepter(Map<String, dynamic> ordre) async {
    final id = ordre['id'] as String?;
    if (id == null) return;

    await queue.submit(SyncAction.accept(id));
    await refresh();
  }

  /// Fait avancer la course.
  ///
  /// [preuveLocale] est le chemin d'une photo prise sur le téléphone. Elle
  /// est mise en file APRÈS le changement de statut : la livraison est le
  /// fait qui compte, la photo l'accompagne. Si l'envoi de l'image échoue,
  /// la livraison reste confirmée.
  Future<void> avancer(String nouveauStatut, {String? preuveLocale}) async {
    final id = courseId;
    if (id == null) return;

    await queue.submit(SyncAction.status(id, nouveauStatut));
    if (preuveLocale != null) {
      await queue.submit(SyncAction.proof(id, preuveLocale));
    }
    await refresh();
  }

  /// Étape suivante du parcours, ou `null` si la course est terminée.
  String? get prochaineEtape => switch (statut) {
        'assigned' => 'picked_up',
        'picked_up' => 'delivering',
        'delivering' => 'delivered',
        _ => null,
      };

  String get libelleProchaineEtape => switch (statut) {
        'assigned' => 'J’ai récupéré la commande',
        'picked_up' => 'Je pars livrer',
        'delivering' => 'Commande livrée',
        _ => '',
      };
}
