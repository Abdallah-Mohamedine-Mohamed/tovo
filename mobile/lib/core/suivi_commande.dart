import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:tovo_suivi/tovo_suivi.dart';

/// Ce que dit le suivi d'une commande à une étape donnée : la phrase, l'étape
/// en mots simples, l'illustration, le segment en cours.
///
/// Les MÊMES textes que la Live Activity de l'iPhone (TovoOrderWidget.swift) :
/// le client lit la même chose quel que soit son téléphone.
@immutable
class EtapeSuivi {
  const EtapeSuivi({
    required this.statut,
    required this.colis,
    this.recuperer = false,
    this.livreur,
    this.client,
    this.boutique = '',
  });

  /// Construit l'étape depuis le message du serveur (FCM, données seules).
  factory EtapeSuivi.depuisMessage(Map<String, dynamic> d) {
    String? texte(String cle) {
      final v = '${d[cle] ?? ''}'.trim();
      return v.isEmpty ? null : v;
    }

    return EtapeSuivi(
      statut: texte('status') ?? 'pending',
      colis: texte('type') == 'courier',
      recuperer: texte('mode') == 'recuperer',
      livreur: texte('driver'),
      client: texte('client'),
      boutique: texte('merchant_name') ?? '',
    );
  }

  final String statut;
  final bool colis;
  final bool recuperer;
  final String? livreur;
  final String? client;
  final String boutique;

  bool get annule => statut == 'cancelled';
  bool get livre => statut == 'delivered';
  bool get fini => annule || livre;

  /// Le segment en cours, de 0 à 3.
  int get index {
    if (colis) {
      return switch (statut) {
        'assigned' => 1,
        'picked_up' || 'delivering' => 2,
        'delivered' => 3,
        _ => 0,
      };
    }
    return switch (statut) {
      'preparing' || 'ready' => 1,
      'assigned' || 'picked_up' || 'delivering' => 2,
      'delivered' => 3,
      _ => 0,
    };
  }

  /// L'illustration 3D de l'étape.
  String get image {
    if (annule) return 'annule';
    if (colis) {
      return switch (statut) {
        'assigned' || 'delivering' => 'scooter',
        'picked_up' => 'colis',
        'delivered' => recuperer ? 'maison' : 'arrivee',
        _ => 'recherche',
      };
    }
    return switch (statut) {
      'pending' => 'attente',
      'confirmed' => 'acceptee',
      'preparing' || 'ready' => 'cuisine',
      'assigned' || 'picked_up' || 'delivering' => 'scooter',
      'delivered' => 'repas',
      _ => 'acceptee',
    };
  }

  /// L'étape, en mots simples.
  String get etape {
    if (annule) return 'Annulée';
    if (colis) {
      return switch (statut) {
        'assigned' => recuperer ? 'Vers votre colis' : 'Livreur en chemin',
        'picked_up' => 'Colis récupéré',
        'delivering' => 'Colis en route',
        'delivered' => recuperer ? 'Colis remis' : 'Colis livré',
        _ => 'Recherche d’un livreur',
      };
    }
    return switch (statut) {
      'pending' => 'Envoyée',
      'confirmed' => 'Confirmée',
      'preparing' => 'En cuisine',
      'ready' => 'Prête',
      'assigned' => 'Livreur trouvé',
      'picked_up' => 'Récupérée',
      'delivering' => 'En route',
      'delivered' => 'Livrée',
      _ => 'En cours',
    };
  }

  /// Le mot de la fin, pour la pastille.
  String get court => annule ? 'Annulée' : (colis ? 'Livré' : 'Livrée');

  /// Le prénom du client n'est dit qu'au DÉBUT de la course (commande
  /// envoyée, confirmée, recherche d'un livreur) et à la FIN (livrée) : à
  /// chaque étape, c'était trop (retour du client, 25/09).
  String? get _prenomClient {
    final c = client;
    if (c == null || c.isEmpty) return null;
    final debutDeCourse = colis
        ? const {'pending', 'confirmed', 'ready'}.contains(statut)
        : const {'pending', 'confirmed'}.contains(statut);
    return debutDeCourse || livre ? c : null;
  }

  /// La phrase de l'étape. Au début et à la fin de la course, elle s'adresse
  /// au client par son prénom ; entre les deux, elle s'en passe.
  String get phrase {
    final nom = (livreur?.isNotEmpty ?? false) ? livreur! : 'Votre livreur';
    final c = _prenomClient;
    String debut(String texte) => c == null
        ? '${texte[0].toUpperCase()}${texte.substring(1)}'
        : '$c, $texte';
    String fin(String texte, [String ponctuation = '']) =>
        c == null ? '$texte$ponctuation' : '$texte, $c$ponctuation';

    if (annule) {
      return debut(
        colis ? 'votre course est annulée' : 'votre commande est annulée',
      );
    }
    if (colis) {
      return switch (statut) {
        'assigned' =>
          recuperer
              ? fin('$nom part chercher votre colis')
              : fin('$nom arrive chercher votre colis'),
        'picked_up' =>
          recuperer
              ? debut('$nom a récupéré votre colis')
              : fin('Colis récupéré', ' !'),
        'delivering' =>
          recuperer
              ? fin('Votre colis arrive')
              : debut('votre colis est en route'),
        'delivered' => fin(
          recuperer ? 'Colis remis, merci' : 'Colis livré, merci',
          ' !',
        ),
        _ => debut('on vous trouve un livreur'),
      };
    }
    return switch (statut) {
      'pending' => debut('$boutique confirme votre commande'),
      'confirmed' => debut('votre commande est confirmée'),
      'preparing' => fin('Votre repas se prépare'),
      'ready' => debut('votre commande est prête'),
      'assigned' => fin('$nom va chercher votre commande'),
      'picked_up' || 'delivering' => debut('$nom arrive avec votre commande'),
      'delivered' => fin('Bon appétit', ' !'),
      _ => fin('Votre commande est en cours'),
    };
  }
}

/// La notification de suivi sur Android, depuis un message du serveur.
///
/// Appelée au premier plan comme en arrière-plan (app fermée). Ne lève
/// jamais : un suivi qui échoue ne doit rien casser d'autre.
class SuiviAndroid {
  const SuiviAndroid._();

  /// Le message du serveur annonce-t-il une étape de suivi ?
  static bool concerne(Map<String, dynamic> donnees) =>
      donnees['kind'] == 'suivi' && '${donnees['order_id'] ?? ''}'.isNotEmpty;

  static Future<void> afficher(Map<String, dynamic> d) async {
    if (!Platform.isAndroid || !concerne(d)) return;
    try {
      final etape = EtapeSuivi.depuisMessage(d);
      final maintenant = DateTime.now();
      final commande =
          DateTime.tryParse('${d['placed_at'] ?? ''}')?.toLocal() ?? maintenant;
      final arrivee = int.tryParse('${d['arrivee'] ?? ''}');
      // L'arrivée calculée par le serveur ; sinon une durée habituelle.
      final prevue = arrivee != null
          ? DateTime.fromMillisecondsSinceEpoch(arrivee * 1000)
          : commande.add(Duration(minutes: etape.colis ? 25 : 40));
      await TovoSuivi.afficher(
        id: '${d['order_id']}',
        phrase: etape.phrase,
        etape: etape.boutique.isEmpty || etape.colis
            ? etape.etape
            : '${etape.etape} · ${etape.boutique}',
        court: etape.court,
        image: etape.image,
        index: etape.index,
        debut: commande.isAfter(maintenant) ? maintenant : commande,
        fin: prevue.isBefore(maintenant.add(const Duration(minutes: 1)))
            ? maintenant.add(const Duration(minutes: 1))
            : prevue,
        fini: etape.fini,
        annule: etape.annule,
        alerte: d['alerte'] == '1' || d['alerte'] == true,
      );
    } catch (cause) {
      debugPrint('[suivi] $cause');
    }
  }
}
