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
    /// Heure d'arrivée (secondes depuis 1970), calculée par le serveur dès
    /// qu'un livreur est en route : « Arrivée vers 14:35 ».
    var arrivee: Double?
  }

  var orderId: String
  /// « food » ou « courier ».
  var kind: String
  /// Nom de la boutique (repas) ou « Votre livraison » (colis).
  var title: String
  /// Colis : « deposer » (on vient chez le client) ou « recuperer » (on
  /// va chercher ailleurs et on apporte au client).
  var mode: String?
  /// Heure de la commande, en secondes depuis 1970 : le temps écoulé
  /// (« Depuis 6:12 ») part de là et tourne tout seul, sans mise à jour.
  var placedAt: Double?
  /// Ancienne arrivée estimée (forfait 18/35 min), plus envoyée ni lue :
  /// gardée pour que les activités déjà lancées se décodent toujours.
  var etaAt: Double?
}
