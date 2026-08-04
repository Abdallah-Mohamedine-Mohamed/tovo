import 'dart:convert';
import 'dart:io';

import 'package:record/record.dart';

/// Enregistrement d'un message vocal.
///
/// Beaucoup de clients parlent bien mieux le français qu'ils ne l'écrivent
/// sur un clavier de téléphone. Dicter sa commande supprime cette barrière —
/// c'est probablement le raccourci le plus utile de l'application pour qui
/// n'écrit pas à l'aise.
///
/// L'enregistrement est envoyé tel quel à l'assistant, qui comprend l'audio
/// directement : pas de transcription intermédiaire, donc pas de service
/// tiers à qui confier la voix des clients, et rien n'est conservé nulle
/// part une fois la réponse rendue.
class VoixTovo {
  VoixTovo._();

  static final AudioRecorder _enregistreur = AudioRecorder();
  static String? _fichier;

  /// Au-delà, ce n'est plus une commande mais un monologue : le modèle
  /// mettrait longtemps à répondre et facturerait chaque seconde.
  static const Duration dureeMax = Duration(seconds: 60);

  /// En dessous, c'est un appui involontaire : envoyer coûterait un appel au
  /// modèle pour du silence.
  static const Duration dureeMin = Duration(milliseconds: 700);

  static bool get enregistreEnCours => _fichier != null;

  /// Demande l'accès au micro et démarre. Renvoie faux si l'accès est refusé.
  static Future<bool> demarrer() async {
    if (!await _enregistreur.hasPermission()) return false;

    final dossier = Directory.systemTemp.path;
    final chemin = '$dossier/tovo_voix_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _enregistreur.start(
      // AAC et non WAV : six secondes de WAV pèsent 286 Ko, une minute d'AAC
      // en fait 240. Sur le réseau nigérien, la différence décide si le
      // message part ou non.
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 24000,
        numChannels: 1,
      ),
      path: chemin,
    );

    _fichier = chemin;
    return true;
  }

  /// Arrête et renvoie l'audio prêt à partir, ou `null` s'il n'y a rien à
  /// envoyer — appui trop court, enregistrement vide, ou fichier absent.
  static Future<({String mime, String data})?> arreter() async {
    final chemin = _fichier;
    _fichier = null;
    if (chemin == null) return null;

    await _enregistreur.stop();

    final fichier = File(chemin);
    if (!await fichier.exists()) return null;

    final octets = await fichier.readAsBytes();
    // Le fichier est supprimé tout de suite : la voix d'un client n'a aucune
    // raison de traîner sur son téléphone après l'envoi.
    await fichier.delete().catchError((_) => fichier);

    // Un fichier minuscule est du silence ou un appui manqué.
    if (octets.length < 2048) return null;

    return (mime: 'audio/mp4', data: base64Encode(octets));
  }

  /// Abandonne l'enregistrement en cours sans rien envoyer.
  static Future<void> annuler() async {
    final chemin = _fichier;
    _fichier = null;
    if (chemin == null) return;

    await _enregistreur.stop();
    await File(chemin).delete().catchError((e) => e as File);
  }

  static Future<void> liberer() => _enregistreur.dispose();
}
