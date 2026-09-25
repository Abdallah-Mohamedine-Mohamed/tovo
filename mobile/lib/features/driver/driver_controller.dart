import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/push.dart';
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
  DriverController({required TovoApi api, SyncQueue? queue, SupabaseClient? db})
    : _api = api,
      _db = db ?? Supabase.instance.client,
      queue = queue ?? SyncQueue(api: api);

  final TovoApi _api;
  final SupabaseClient _db;
  final SyncQueue queue;

  Timer? _ping;
  Timer? _rafraichissement;
  RealtimeChannel? _canal;
  StreamSubscription<Map<String, String>>? _notifications;
  Future<void>? _refreshEnCours;
  bool _refreshApres = false;
  bool _presenceEnCours = false;
  String? _acceptationEnCours;
  bool _disposed = false;

  bool _online = false;
  bool get online => _online;
  bool get presenceEnCours => _presenceEnCours;
  bool acceptationEnCours(String id) =>
      _acceptationEnCours == id || queue.hasPendingAccept(id);

  bool chargement = false;
  String? erreur;

  void effacerErreur() {
    erreur = null;
    notifyListeners();
  }

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
    final userId = _db.auth.currentUser?.id;
    if (userId != null) {
      try {
        final profile = await _db
            .from('driver_profiles')
            .select('is_online')
            .eq('id', userId)
            .maybeSingle();
        _online = profile?['is_online'] == true;
      } on Exception {
        _online = false;
      }
    }
    _ecouter();
    await refresh();
    _notifications = TovoPush.messagesEnAvantPlan().listen((message) {
      if (message['kind'] == 'dispatch' ||
          message['kind'] == 'assigned' ||
          message['kind'] == 'order_ready' ||
          message['kind'] == 'incoming_order') {
        unawaited(refresh(silencieux: true));
      }
    });
    _programmerRafraichissement();
  }

  @override
  void dispose() {
    _disposed = true;
    _ping?.cancel();
    _rafraichissement?.cancel();
    _notifications?.cancel();
    if (_canal != null) _db.removeChannel(_canal!);
    queue.dispose();
    super.dispose();
  }

  void _ecouter() {
    if (_canal != null) return;
    _canal = _db
        .channel('tovo:driver:orders')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          callback: (_) => unawaited(refresh(silencieux: true)),
        )
        .subscribe();
  }

  // ------------------------------------------------------------------
  // Disponibilité
  // ------------------------------------------------------------------

  Future<void> setOnline(bool valeur) async {
    if (_presenceEnCours || _online == valeur) return;
    final id = _db.auth.currentUser?.id;
    if (id == null) return;
    _presenceEnCours = true;
    if (valeur &&
        !await TovoLocation.ensurePermission(requestPermission: true)) {
      erreur = 'Activez la localisation pour recevoir des courses.';
      _presenceEnCours = false;
      notifyListeners();
      return;
    }
    _online = valeur;
    notifyListeners();
    try {
      await _db
          .from('driver_profiles')
          .update({'is_online': valeur})
          .eq('id', id);
      _programmerPing();
      if (valeur) unawaited(refresh(silencieux: true));
      if (!valeur && course == null) {
        pool = const [];
        notifyListeners();
      }
    } on Exception {
      _online = !valeur;
      erreur = 'Disponibilité non enregistrée. Réessayez.';
      _programmerPing();
    } finally {
      _presenceEnCours = false;
      notifyListeners();
    }
  }

  /// Cadence du ping de position.
  ///
  /// 10 s en course : c'est ce qui alimente la carte du client, et une
  /// position vieille d'une minute ne sert à rien pour suivre une moto.
  /// 60 s au repos : le dispatch a seulement besoin de savoir dans quel
  /// quartier se trouve le livreur.
  /// Rien hors ligne : la batterie et le forfait data d'un livreur sont des
  /// ressources qu'il paie lui-même.
  Duration get _cadencePing => course != null
      ? const Duration(seconds: 10)
      : const Duration(seconds: 60);

  void _programmerPing() {
    _ping?.cancel();
    if (!_online && course == null) return;

    _ping = Timer.periodic(_cadencePing, (_) => _envoyerPosition());
    unawaited(_envoyerPosition());
  }

  Future<void> _envoyerPosition() async {
    if (!_online && course == null) return;

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

  Future<void> refresh({bool silencieux = false}) {
    final enCours = _refreshEnCours;
    if (enCours != null) {
      _refreshApres = true;
      return enCours;
    }
    final future = _charger(silencieux: silencieux);
    _refreshEnCours = future;
    return future.whenComplete(() {
      _refreshEnCours = null;
      if (_refreshApres) {
        _refreshApres = false;
        unawaited(refresh(silencieux: true));
      }
    });
  }

  Future<void> _charger({required bool silencieux}) async {
    if (!silencieux) {
      chargement = true;
      erreur = null;
      notifyListeners();
    }

    await queue.flush();
    if (queue.hasPendingOrderChange && course != null) {
      chargement = false;
      notifyListeners();
      return;
    }

    final ordersRequest = _api.get('/orders', query: {'limit': 5});
    final summaryRequest = _api.get('/driver/summary');
    final poolRequest = _online && course == null
        ? _api.get('/driver/pool')
        : null;
    final courses = await ordersRequest;
    if (_disposed) return;
    if (!courses.ok) {
      erreur = 'Impossible de vérifier les courses. Réessayez.';
      pool = const [];
      chargement = false;
      notifyListeners();
      return;
    }
    final enCours = _trouverCourseActive(courses);

    if (enCours != null) {
      final suivi = await _api.get('/orders/$enCours');
      if (suivi.ok && suivi.components.isNotEmpty) {
        course = suivi.components.first.data;
      } else {
        erreur = 'Impossible de charger la course en cours. Réessayez.';
      }
      pool = const [];
    } else if (courses.ok && !queue.hasPendingOrderChange) {
      course = null;
      if (_online) {
        final reponse = await (poolRequest ?? _api.get('/driver/pool'));
        if (_disposed) return;
        if (reponse.ok) {
          pool = _extraireOrdres(reponse);
        } else {
          pool = const [];
          erreur = 'Impossible de vérifier les courses. Réessayez.';
        }
      } else {
        pool = const [];
      }
    }

    if (!queue.hasPendingOrderChange) _acceptationEnCours = null;
    chargement = false;
    _programmerPing();
    notifyListeners();

    final summary = await summaryRequest;
    if (_disposed) return;
    if (summary.ok && summary.raw.isNotEmpty) {
      resume = summary.raw;
      notifyListeners();
    }
  }

  static const _statutsActifs = {'assigned', 'picked_up', 'delivering'};

  /// Acceptée pendant la préparation (migration 0062) : la course est à lui,
  /// mais la boutique ne l'a pas encore marquée « prête ».
  static const _statutsAvantPret = {'confirmed', 'preparing', 'ready'};

  String? _trouverCourseActive(TovoResponse reponse) {
    if (!reponse.ok) return null;
    final moi = _db.auth.currentUser?.id;
    for (final ordre in _extraireOrdres(reponse)) {
      final statut = ordre['status'];
      // Le pool est lisible aussi : seule une commande qui porte SON nom
      // est sa course, quand elle n'est pas encore « assigned ».
      if (_statutsActifs.contains(statut) ||
          (_statutsAvantPret.contains(statut) &&
              moi != null &&
              ordre['driver_id'] == moi)) {
        return ordre['id'] as String?;
      }
    }
    return null;
  }

  /// La course est acceptée, mais la boutique cuisine encore.
  bool get enPreparation => _statutsAvantPret.contains(statut);

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
    if (id == null || course != null || acceptationEnCours(id)) return;

    _acceptationEnCours = id;
    notifyListeners();
    final rejetsAvant = queue.rejets.length;
    await queue.submit(SyncAction.accept(id));
    unawaited(_finaliserAcceptation(id, rejetsAvant));
  }

  Future<void> _finaliserAcceptation(String id, int rejetsAvant) async {
    await queue.flush();
    if (queue.hasPendingAccept(id)) return;
    _acceptationEnCours = null;
    final refus = queue.rejets
        .skip(rejetsAvant)
        .where((rejet) => rejet.action.path == '/orders/$id/accept')
        .firstOrNull;
    if (refus != null) erreur = refus.message;
    notifyListeners();
    await refresh(silencieux: true);
  }

  /// Fait avancer la course.
  ///
  /// [preuveLocale] est le chemin d'une photo prise sur le téléphone. Elle
  /// est mise en file APRÈS le changement de statut : la livraison est le
  /// fait qui compte, la photo l'accompagne. Si l'envoi de l'image échoue,
  /// la livraison reste confirmée.
  Future<void> avancer(String nouveauStatut, {String? preuveLocale}) async {
    final id = courseId;
    if (id == null ||
        queue.hasPendingOrderChange ||
        prochaineEtape != nouveauStatut) {
      return;
    }

    final ancienStatut = statut;
    final rejetsAvant = queue.rejets.length;
    course = {...course!, 'status': nouveauStatut};
    notifyListeners();
    await queue.submit(SyncAction.status(id, nouveauStatut));
    if (preuveLocale != null) {
      await queue.submit(SyncAction.proof(id, preuveLocale));
    }
    unawaited(_finaliserStatut(id, ancienStatut, nouveauStatut, rejetsAvant));
  }

  Future<void> _finaliserStatut(
    String id,
    String ancienStatut,
    String nouveauStatut,
    int rejetsAvant,
  ) async {
    await queue.flush();
    final refus = queue.rejets
        .skip(rejetsAvant)
        .where(
          (rejet) =>
              rejet.action.path == '/orders/$id/status' &&
              rejet.action.body['status'] == nouveauStatut,
        )
        .firstOrNull;
    if (refus != null && courseId == id) {
      course = {...course!, 'status': ancienStatut};
      erreur = refus.message;
      notifyListeners();
    }
    if (!queue.hasPendingOrderChange) await refresh(silencieux: true);
  }

  /// Le client a-t-il choisi Nita sans que le paiement soit constaté ?
  ///
  /// Nita permet aussi d'envoyer l'argent directement, sans passer par
  /// l'achat en ligne : le système ne peut alors rien voir. C'est au livreur
  /// de trancher, puisque c'est lui qui est devant le client.
  bool get paiementNitaADemander =>
      course?['payment_method'] == 'mobile_money' &&
      course?['payment_status'] == 'pending';

  /// Le livreur déclare avoir constaté le paiement.
  ///
  /// Le serveur revérifie d'abord auprès de Nita : si le client avait déjà
  /// réglé son achat en ligne, l'encaissement est attribué à Nita et non au
  /// livreur — on ne lui impute pas un versement qu'il n'a pas reçu.
  Future<void> confirmerPaiement() async {
    final id = courseId;
    if (id == null) return;

    await queue.submit(SyncAction.paiementRecu(id));
    await refresh();
  }

  /// Étape suivante du parcours, ou `null` si la course est terminée.
  String? get prochaineEtape => etapeSuivante(statut);

  static String? etapeSuivante(String statut) => switch (statut) {
    'assigned' => 'picked_up',
    'picked_up' => 'delivering',
    'delivering' => 'delivered',
    _ => null,
  };

  String get libelleProchaineEtape => switch (statut) {
    'assigned' =>
      course?['type'] == 'courier' ? 'Colis récupéré' : 'Repas récupéré',
    'picked_up' => 'Je pars livrer',
    'delivering' =>
      course?['type'] == 'courier' ? 'Colis livré' : 'Commande livrée',
    _ => '',
  };
}
