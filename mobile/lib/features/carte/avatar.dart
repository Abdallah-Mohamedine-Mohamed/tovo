import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';
import '../../core/position_livreur.dart';

/// L'avatar du client sur la carte (validé le 07/10, de jour comme de nuit) :
/// il attend, marche ou court selon sa vitesse RÉELLE ; en voiture ou à moto,
/// il court. Comme la moto du suivi, Google Maps n'affiche que des images :
/// on montre la vue du personnage qui correspond à son cap vu de la caméra,
/// à l'inclinaison de la caméra, et au moment exact de son pas.
///
/// Images : outils/avatars (generer.cjs, publier.cjs), stockage Supabase
/// public « avatars ». Seules les bandes utiles sont téléchargées, puis
/// gardées sur le téléphone.

enum AnimationAvatar { attente, marche, course, salut }

extension on AnimationAvatar {
  String get fichier => switch (this) {
    AnimationAvatar.attente => 'idle',
    AnimationAvatar.marche => 'walk',
    AnimationAvatar.course => 'run',
    AnimationAvatar.salut => 'wave',
  };
  String get cle => switch (this) {
    AnimationAvatar.attente => 'Idle',
    AnimationAvatar.marche => 'Walk',
    AnimationAvatar.course => 'Run',
    AnimationAvatar.salut => 'Wave',
  };
}

/// Un cycle d'animation : son nombre d'images, sa durée, sa foulée.
class Cycle {
  const Cycle({required this.images, required this.dureeS, this.fouleeM});
  final int images;
  final double dureeS;

  /// Mètres parcourus pendant un cycle (marche, course) : l'image affichée
  /// suit la distance, et un pas affiché vaut un pas réel.
  final double? fouleeM;
}

/// Ce que le manifeste dit d'un avatar ; valeurs par défaut si absent.
class FicheAvatar {
  const FicheAvatar(this.cycles);
  final Map<AnimationAvatar, Cycle> cycles;

  static const parDefaut = FicheAvatar({
    AnimationAvatar.attente: Cycle(images: 8, dureeS: 2.08),
    AnimationAvatar.marche: Cycle(images: 12, dureeS: 1.67, fouleeM: 2.25),
    AnimationAvatar.course: Cycle(images: 10, dureeS: 1, fouleeM: 3.9),
    AnimationAvatar.salut: Cycle(images: 12, dureeS: 2.08),
  });
}

/// L'état affiché à un instant.
class EtatAvatar {
  const EtatAvatar({
    required this.position,
    required this.animation,
    required this.image,
    required this.capDeg,
  });
  final Point position;
  final AnimationAvatar animation;
  final int image;

  /// Cap géographique (0 = nord), ou null s'il n'a encore jamais bougé.
  final double? capDeg;
}

/// Le moteur : des mesures GPS en entrée, l'état de l'avatar en sortie.
/// Du calcul pur, sans plateforme : testé à part.
class MoteurAvatar {
  MoteurAvatar({this.fiche = FicheAvatar.parDefaut, bool saluer = true})
    : _animation = saluer && fiche.cycles.containsKey(AnimationAvatar.salut)
          ? AnimationAvatar.salut
          : AnimationAvatar.attente;

  final FicheAvatar fiche;

  // Seuils, en m/s (extrêmement précis, demande du fondateur) : bas pour
  // réagir au premier pas, avec un écart entrée/sortie (hystérésis) et une
  // durée minimale, pour ne pas changer d'allure à cause d'un bruit de GPS.
  static const marcheDebut = 0.30; // 1,1 km/h, pendant 0,4 s
  static const marcheFin = 0.15; //   0,5 km/h, pendant 0,8 s
  static const courseDebut = 2.2; //  7,9 km/h
  static const courseFin = 1.8; //    6,5 km/h
  static const precisionMaxM = 30.0;

  AnimationAvatar _animation;
  double _vitesse = 0; // lissée
  double _depuis = 0; // durée dans la condition de changement
  double _temps = 0; // horloge de l'animation (attente, salut)
  double _distance = 0; // distance parcourue (marche, course)
  double? _cap;
  Point? _fix;
  Point? _affiche;
  double _vx = 0, _vy = 0; // m/s, est et nord
  double _depuisFix = 0;
  final _historique = <({DateTime t, Point p, double precision})>[];
  double _precision = 0;
  double _vitesseGps = -1;
  double? _vitesseDeplacement;
  DateTime? _dernierFix;

  /// Diagnostic : la vitesse tirée des positions (m/s), le nombre de
  /// positions reçues par seconde, et l'âge de la dernière.
  double? get vitesseDeplacement => _vitesseDeplacement;
  double get positionsParSeconde {
    if (_historique.length < 2) return 0;
    final duree =
        _historique.last.t.difference(_historique.first.t).inMilliseconds /
        1000;
    return duree <= 0 ? 0 : (_historique.length - 1) / duree;
  }

  double? ageDerniereMesure([DateTime? maintenant]) {
    final d = _dernierFix;
    return d == null
        ? null
        : (maintenant ?? DateTime.now()).difference(d).inMilliseconds / 1000;
  }

  /// Diagnostic des essais : précision (m) et vitesse brute du GPS (m/s).
  double get precision => _precision;
  double get vitesseGps => _vitesseGps;

  AnimationAvatar get animation => _animation;
  double get vitesse => _vitesse;

  /// Une mesure GPS. `vitesseMs` : vitesse Doppler (la plus fiable) ;
  /// `capDeg` : cap du GPS (fiable seulement en mouvement).
  void gps(
    Point p, {
    required double vitesseMs,
    double? capDeg,
    double precisionM = 5,
    DateTime? instant,
  }) {
    final maintenant = instant ?? DateTime.now();
    _precision = precisionM;
    _vitesseGps = vitesseMs;
    final precis = precisionM <= precisionMaxM;
    // Les 4 dernières secondes de mesures : une vitesse et un cap DE SECOURS,
    // tirés du déplacement réel. Sur iPhone, la vitesse du GPS vaut −1 quand
    // elle n'est pas disponible : l'avatar restait figé (essai du 07/10).
    if (precis) _historique.add((t: maintenant, p: p, precision: precisionM));
    _historique.removeWhere(
      (h) => maintenant.difference(h.t).inMilliseconds > 4000,
    );
    double? vitesseDeplacement;
    double? capDeplacement;
    if (_historique.length >= 2) {
      final a = _historique.first, b = _historique.last;
      final dt = b.t.difference(a.t).inMilliseconds / 1000;
      if (dt >= 1.5) {
        final d = metres(a.p, b.p);
        // Un déplacement plus petit que la précision du GPS n'en est pas un.
        final seuil = math.max(4.0, (a.precision + b.precision) / 2);
        // Et un vrai déplacement va DANS UNE DIRECTION : le chemin suivi est
        // presque droit. Un tremblement zigzague (chemin bien plus long que
        // l'écart net) : ce n'est pas une marche.
        var chemin = 0.0;
        for (var i = 1; i < _historique.length; i++) {
          chemin += metres(_historique[i - 1].p, _historique[i].p);
        }
        final droit = chemin == 0 || d / chemin > 0.7;
        // La moyenne sur 4 s écarte le tremblement, mais traîne au freinage :
        // le dernier tronçon, s'il est plus lent, l'emporte.
        final avant = _historique[_historique.length - 2];
        final dtDernier = b.t.difference(avant.t).inMilliseconds / 1000;
        final dernier = dtDernier > 0
            ? metres(avant.p, b.p) / dtDernier
            : double.infinity;
        vitesseDeplacement = d > seuil && droit ? math.min(d / dt, dernier) : 0;
        if (d > seuil && droit) capDeplacement = cap(a.p, b.p);
      }
    }
    final doppler = vitesseMs.isFinite && vitesseMs >= 0 ? vitesseMs : null;
    double v;
    if (!precis) {
      v = 0;
    } else {
      // La plus grande des deux : celle du GPS, et celle tirée du déplacement
      // réel (filtrée contre le tremblement : chemin droit, au-delà de la
      // précision). Essai du 08/10 en voiture : le GPS de l'iPhone disait
      // 0,2 m/s à 50 km/h (compteur), et l'avatar marchait.
      v = math.max(doppler ?? 0, vitesseDeplacement ?? 0);
    }
    _vitesseDeplacement = vitesseDeplacement;
    _dernierFix = maintenant;
    // Lissage du seul BRUIT : une petite variation est amortie ; un vrai
    // changement d'allure (plus de 1 m/s d'écart, la moto qui freine) est
    // suivi presque aussitôt — sinon l'avatar courait encore 3 s après.
    final ecart = (v - _vitesse).abs();
    final alpha = ecart > 1.0 ? 0.75 : (v > _vitesse ? 0.55 : 0.4);
    _vitesse += (v - _vitesse) * alpha;
    if (_vitesse < 0.05) _vitesse = 0;
    // Le cap ne change que s'il bouge VRAIMENT : à l'arrêt, le GPS tremble
    // de quelques mètres et la caméra tournait en rond (essai du 07/10).
    if (_vitesse > 0.6) {
      if (capDeg != null &&
          capDeg.isFinite &&
          capDeg >= 0 &&
          doppler != null &&
          doppler > 0.6) {
        _cap = capDeg;
      } else if (capDeplacement != null) {
        _cap = capDeplacement;
      }
    }
    final c = _cap;
    if (c != null && _vitesse > 0) {
      final r = c * math.pi / 180;
      _vx = math.sin(r) * _vitesse;
      _vy = math.cos(r) * _vitesse;
    } else {
      _vx = _vy = 0;
    }
    // À l'arrêt, la position reste stable : un tremblement plus petit que la
    // précision ne déplace ni l'avatar, ni l'écart au trajet.
    final ancien = _fix;
    final immobile =
        _vitesse == 0 &&
        ancien != null &&
        metres(ancien, p) < math.max(5.0, precisionM);
    if (!immobile) _fix = p;
    _affiche ??= p;
    _depuisFix = 0;
  }

  /// La position stabilisée (pour l'écart au trajet et les recalculs).
  Point? get position => _fix;

  /// En mouvement réel (pas un tremblement du GPS).
  bool get enMouvement => _vitesse > 0.3;

  /// Avance de `dt` secondes ; renvoie ce qu'il faut afficher.
  EtatAvatar? avancer(double dt) {
    final fix = _fix;
    if (fix == null) return null;
    _temps += dt;
    _depuisFix += dt;
    _changerAllure(dt);
    // Position : la dernière mesure prolongée par la vitesse (au plus
    // 1,2 s), rejointe en douceur pour ne jamais sauter.
    final ext = math.min(_depuisFix, 1.2);
    final cible = _decaler(fix, _vx * ext, _vy * ext);
    final a = _affiche!;
    final k = math.min(1.0, dt * 6);
    _affiche = (
      lat: a.lat + (cible.lat - a.lat) * k,
      lng: a.lng + (cible.lng - a.lng) * k,
    );
    final cycle =
        fiche.cycles[_animation] ?? fiche.cycles[AnimationAvatar.attente]!;
    int image;
    if (cycle.fouleeM != null) {
      _distance += _vitesse * dt;
      image =
          ((_distance / cycle.fouleeM!) * cycle.images).floor() % cycle.images;
    } else {
      image = ((_temps / cycle.dureeS) * cycle.images).floor() % cycle.images;
    }
    return EtatAvatar(
      position: _affiche!,
      animation: _animation,
      image: image,
      capDeg: _cap,
    );
  }

  void _changerAllure(double dt) {
    final v = _vitesse;
    AnimationAvatar? vers;
    double attendre = 0;
    switch (_animation) {
      case AnimationAvatar.salut:
        // Un salut à l'ouverture, une fois, sauf s'il part tout de suite.
        if (v >= marcheDebut) {
          vers = AnimationAvatar.marche;
        } else if (_temps >=
            (fiche.cycles[AnimationAvatar.salut]?.dureeS ?? 2)) {
          vers = AnimationAvatar.attente;
        }
      case AnimationAvatar.attente:
        if (v >= courseDebut) {
          vers = AnimationAvatar.course;
        } else if (v >= marcheDebut) {
          vers = AnimationAvatar.marche;
          attendre = 0.4;
        }
      case AnimationAvatar.marche:
        if (v >= courseDebut) {
          vers = AnimationAvatar.course;
          attendre = 0.3;
        } else if (v < marcheFin) {
          vers = AnimationAvatar.attente;
          attendre = 0.8;
        }
      case AnimationAvatar.course:
        if (v < marcheFin) {
          vers = AnimationAvatar.attente;
          attendre = 0.8;
        } else if (v < courseFin) {
          vers = AnimationAvatar.marche;
          attendre = 0.5;
        }
    }
    if (vers == null) {
      _depuis = 0;
      return;
    }
    _depuis += dt;
    if (_depuis >= attendre) {
      _animation = vers;
      _depuis = 0;
      _temps = 0;
    }
  }

  static Point _decaler(Point p, double estM, double nordM) => (
    lat: p.lat + nordM / 111320,
    lng: p.lng + estM / (111320 * math.cos(p.lat * math.pi / 180)),
  );
}

/// Les images d'un avatar : manifeste, bandes téléchargées à la demande et
/// gardées sur le téléphone, découpées en images de repère.
class ImagesAvatar {
  ImagesAvatar(this.cle, {this.largeurPt = 76});

  final String cle;
  final double largeurPt;

  static const inclinaisons = [0, 30, 45, 60];
  static const directions = 24;

  /// L'ancrage : les pieds, à 85,1 % de la hauteur de l'image.
  static const ancre = Offset(0.5, 0.851);

  static String get _base =>
      '${TovoConfig.supabaseUrl}/storage/v1/object/public/avatars';

  /// Les personnages, dans l'ordre du choix (étape 5, 07/10).
  static const personnages = {
    'femme': 'Femme',
    'capuche': 'Capuche',
    'aventurier': 'Aventurier',
    'homme': 'Homme',
  };

  static Future<String> choisi() async {
    final prefs = await SharedPreferences.getInstance();
    final cle = prefs.getString('avatar');
    return personnages.containsKey(cle) ? cle! : 'femme';
  }

  static Future<void> choisir(String cle) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('avatar', cle);
  }

  FicheAvatar fiche = FicheAvatar.parDefaut;
  final Map<String, List<BitmapDescriptor>> _bandes = {};
  final Map<String, Future<List<BitmapDescriptor>?>> _enCours = {};

  Future<void> chargerFiche() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/manifest.json'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final a =
          (m['avatars'] as Map<String, dynamic>?)?[cle]
              as Map<String, dynamic>?;
      if (a == null) return;
      final cycles = <AnimationAvatar, Cycle>{};
      for (final anim in AnimationAvatar.values) {
        final c = a[anim.cle] as Map<String, dynamic>?;
        if (c == null) continue;
        cycles[anim] = Cycle(
          images: (c['images'] as num).toInt(),
          dureeS: (c['duree_cycle_s'] as num).toDouble(),
          fouleeM: (c['foulee_m'] as num?)?.toDouble(),
        );
      }
      if (cycles.containsKey(AnimationAvatar.attente)) {
        fiche = FicheAvatar(cycles);
      }
    } catch (_) {
      // Les valeurs par défaut font l'affaire.
    }
  }

  /// L'inclinaison des images pour celle de la caméra. Une personne vue de
  /// dessus n'est qu'une tête : sous 37,5°, on la montre de 45°, debout,
  /// comme les repères d'une carte.
  static int inclinaisonPour(double tiltCamera) {
    if (tiltCamera < 37.5) return 45;
    return tiltCamera < 52.5 ? 45 : 60;
  }

  /// La direction des images : le cap vu de la caméra, tous les 15°.
  static int directionPour(double? capDeg, double bearingCamera) {
    // Sans cap connu (il n'a pas encore bougé) : de face.
    if (capDeg == null) return 180;
    final relatif = (capDeg - bearingCamera + 720) % 360;
    return ((relatif / 15).round() % directions) * 15;
  }

  String _nom(AnimationAvatar a, int t, int d) =>
      '${a.fichier}_t${t}_${d.toString().padLeft(3, '0')}.webp';

  /// Les images d'une bande, si elle est prête ; lance son chargement sinon.
  List<BitmapDescriptor>? bande(AnimationAvatar a, int t, int d, double ratio) {
    final nom = _nom(a, t, d);
    final pret = _bandes[nom];
    if (pret != null) return pret;
    _enCours[nom] ??= _charger(nom, ratio, fiche.cycles[a]?.images ?? 1).then((
      v,
    ) {
      if (v != null) _bandes[nom] = v;
      // Échec : on réessaiera au prochain besoin.
      unawaited(_enCours.remove(nom));
      return v;
    });
    return null;
  }

  Future<List<BitmapDescriptor>?> _charger(
    String nom,
    double ratio,
    int images,
  ) async {
    try {
      final octets = await octetsBande(cle, nom);
      if (octets == null) return null;
      final codec = await ui.instantiateImageCodec(octets);
      final bande = (await codec.getNextFrame()).image;
      final cote = bande.height;
      final n = math.max(1, (bande.width / cote).round());
      final sortie = <BitmapDescriptor>[];
      for (var i = 0; i < math.min(n, images); i++) {
        final r = ui.PictureRecorder();
        Canvas(r).drawImageRect(
          bande,
          Rect.fromLTWH(
            i * cote.toDouble(),
            0,
            cote.toDouble(),
            cote.toDouble(),
          ),
          Rect.fromLTWH(0, 0, cote.toDouble(), cote.toDouble()),
          Paint()..filterQuality = FilterQuality.medium,
        );
        final image = await r.endRecording().toImage(cote, cote);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        sortie.add(
          BitmapDescriptor.bytes(
            png!.buffer.asUint8List(),
            width: largeurPt,
            height: largeurPt,
          ),
        );
      }
      return sortie;
    } catch (e) {
      debugPrint('avatar : bande $nom illisible ($e)');
      return null;
    }
  }

  /// Une bande : depuis le téléphone, sinon téléchargée puis gardée.
  static Future<Uint8List?> octetsBande(String cle, String nom) async {
    final dossier = Directory(
      '${(await getApplicationSupportDirectory()).path}/avatars/$cle',
    );
    final fichier = File('${dossier.path}/$nom');
    if (await fichier.exists()) return fichier.readAsBytes();
    final r = await http
        .get(Uri.parse('$_base/$cle/$nom'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    await dossier.create(recursive: true);
    await fichier.writeAsBytes(r.bodyBytes, flush: true);
    return r.bodyBytes;
  }

  /// Précharge toutes les directions de ces animations (une bande à la
  /// fois) : au premier « Y aller », l'avatar est déjà là (essai du 07/10).
  Future<void> precharger(
    List<AnimationAvatar> anims,
    int t,
    double ratio,
  ) async {
    for (final a in anims) {
      if (!fiche.cycles.containsKey(a)) continue;
      for (var d = 0; d < 360; d += 15) {
        final nom = _nom(a, t, d);
        if (_bandes.containsKey(nom)) continue;
        bande(a, t, d, ratio);
        await _enCours[nom];
      }
    }
  }

  /// Prépare les bandes voisines (directions ± 15°) : pas d'attente quand
  /// il tourne.
  void prechauffer(AnimationAvatar a, int t, int d, double ratio) {
    for (final dd in [d, (d + 15) % 360, (d + 345) % 360]) {
      bande(a, t, dd, ratio);
    }
  }
}
