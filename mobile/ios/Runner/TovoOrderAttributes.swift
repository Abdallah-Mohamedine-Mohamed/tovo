import ActivityKit

/// Partagé par l'app (qui démarre l'activité) et le widget (qui la dessine).
///
/// Tout ce qui s'ajoute est FACULTATIF : une activité déjà lancée, ou une
/// mise à jour du serveur qui n'envoie que `status`, doit toujours se lire.
@available(iOS 16.2, *)
struct TovoOrderAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var status: String
    /// Prénom du livreur, dès qu'il a accepté la course.
    var driver: String?
  }

  var orderId: String
  /// « food » ou « courier ».
  var kind: String
  /// Nom de la boutique (repas) ou « Votre livraison » (colis).
  var title: String
  /// Colis : « deposer » (on vient chez le client) ou « recuperer » (on
  /// va chercher ailleurs et on apporte au client).
  var mode: String?
  /// Heure de la commande, en secondes depuis 1970 : le chronomètre part de
  /// là et tourne tout seul, sans aucune mise à jour.
  var placedAt: Double?
}
