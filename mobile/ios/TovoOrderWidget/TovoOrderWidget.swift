import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// Le suivi de commande sur l'écran verrouillé et dans la Dynamic Island,
// dans l'esprit d'Uber Eats : fond noir, « Tovo » bien lisible, un grand
// titre, un compte à rebours qui défile tout seul (« Arrive dans 17:42 »),
// une illustration 3D ronde qui change à chaque étape, et des segments
// espacés en bas. Le titre et l'illustration s'animent à chaque étape.
//
// Tout ce qui défile (compte à rebours) le fait SANS mise à jour du
// serveur : c'est le système qui compte. Les étapes, elles, arrivent par
// push APNs, app fermée.

private let menthe = Color(red: 0.42, green: 0.86, blue: 0.76)
private let brume = Color.white.opacity(0.64)
private let eteint = Color.white.opacity(0.24)

/// Geist, embarquée dans le widget (Ressources, déclarée dans Info.plist).
/// Si elle manquait, SwiftUI retomberait sur la police système.
private func geist(_ taille: CGFloat, demiGras: Bool = true) -> Font {
  .custom(demiGras ? "Geist-SemiBold" : "Geist-Medium", size: taille)
}

/// Une illustration 3D (Fluent Emoji, licence MIT) du dossier Ressources.
private func illustration(_ nom: String) -> UIImage? {
  guard let url = Bundle.main.url(forResource: nom, withExtension: "png", subdirectory: "Ressources") else {
    return nil
  }
  return UIImage(contentsOfFile: url.path)
}

@available(iOS 16.2, *)
private struct Parcours {
  let status: String
  let kind: String
  let mode: String
  let driver: String?
  let boutique: String

  var colis: Bool { kind == "courier" }
  var recuperer: Bool { colis && mode == "recuperer" }
  var annule: Bool { status == "cancelled" }
  var livre: Bool { status == "delivered" }
  var fini: Bool { annule || livre }

  /// Nombre de segments, et celui qui est en cours (0 à 3).
  let segments = 4
  var index: Int {
    if colis {
      switch status {
      case "assigned": return 1
      case "picked_up", "delivering": return 2
      case "delivered": return 3
      default: return 0
      }
    }
    switch status {
    case "preparing", "ready": return 1
    case "assigned", "picked_up", "delivering": return 2
    case "delivered": return 3
    default: return 0
    }
  }

  /// L'illustration de l'étape : elle change à chaque statut qui compte.
  var image: String {
    if annule { return "annule" }
    if colis {
      switch status {
      case "assigned", "delivering": return "scooter"
      case "picked_up": return "colis"
      case "delivered": return recuperer ? "maison" : "arrivee"
      default: return "recherche"
      }
    }
    switch status {
    case "pending": return "attente"
    case "confirmed": return "acceptee"
    case "preparing", "ready": return "cuisine"
    case "assigned", "picked_up", "delivering": return "scooter"
    case "delivered": return "repas"
    default: return "acceptee"
    }
  }

  var titre: String {
    if annule { return colis ? "Course annulée" : "Commande annulée" }
    if colis {
      switch status {
      case "assigned": return recuperer ? "Il part chercher le colis" : "Votre livreur arrive"
      case "picked_up": return "Colis récupéré"
      case "delivering": return recuperer ? "Votre colis arrive" : "Colis en route"
      case "delivered": return recuperer ? "Colis remis" : "Colis livré"
      default: return "On cherche un livreur"
      }
    }
    switch status {
    case "pending": return "La boutique confirme…"
    case "confirmed": return "Commande acceptée"
    case "preparing": return "En cuisine…"
    case "ready": return "Prête, un livreur arrive"
    case "assigned": return "Un livreur va la chercher"
    case "picked_up", "delivering": return "En route vers vous"
    case "delivered": return "Bon appétit !"
    default: return "Votre commande"
    }
  }

  var sousTitre: String {
    if annule { return "Vous pouvez recommander quand vous voulez." }
    if livre { return colis ? "Merci d’avoir fait confiance à Tovo." : "Dites-nous comment c’était." }
    if let nom = driver, !nom.isEmpty {
      switch status {
      case "assigned": return recuperer || !colis ? "\(nom) est en route" : "\(nom) arrive chez vous"
      case "picked_up", "delivering": return colis && !recuperer ? "\(nom) livre votre colis" : "\(nom) vous l’apporte"
      default: return "Avec \(nom)"
      }
    }
    return colis ? "Dès qu’un livreur accepte, il apparaît ici." : boutique
  }

  var motCourt: String { annule ? "Annulée" : (colis ? "Livré" : "Livrée") }
}

/// L'illustration dans un rond cerclé de blanc, comme la photo d'Uber.
@available(iOS 16.2, *)
private struct Medaillon: View {
  let nom: String
  let taille: CGFloat
  var cercle = true

  var body: some View {
    ZStack {
      if cercle {
        Circle().fill(Color.white.opacity(0.14))
        Circle().stroke(Color.white, lineWidth: max(2, taille / 22))
      }
      if let image = illustration(nom) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .padding(cercle ? taille * 0.16 : 0)
      }
    }
    .frame(width: taille, height: taille)
  }
}

/// Les segments espacés : faits en menthe, l'étape en cours en menthe
/// adoucie, le reste éteint.
@available(iOS 16.2, *)
private struct Segments: View {
  let parcours: Parcours

  var body: some View {
    HStack(spacing: 10) {
      ForEach(0..<parcours.segments, id: \.self) { i in
        Capsule()
          .fill(couleur(i))
          .frame(height: 5)
      }
    }
  }

  private func couleur(_ i: Int) -> Color {
    if parcours.annule { return eteint }
    if i < parcours.index || parcours.livre { return menthe }
    if i == parcours.index { return menthe.opacity(0.5) }
    return eteint
  }
}

/// « Arrive dans 17:42 », qui défile tout seul ; sinon la phrase de l'étape.
@available(iOS 16.2, *)
private struct Arrivee: View {
  let parcours: Parcours
  let eta: Date?
  let taille: CGFloat

  var body: some View {
    if !parcours.fini, let eta, eta > Date() {
      (Text("Arrive dans ").foregroundColor(brume)
        + Text(timerInterval: Date()...eta, countsDown: true).foregroundColor(menthe))
        .font(geist(taille, demiGras: false))
        .monospacedDigit()
        .lineLimit(1)
    } else {
      Text(parcours.sousTitre)
        .font(geist(taille, demiGras: false))
        .foregroundColor(brume)
        .lineLimit(1)
    }
  }
}

/// Le compte à rebours seul, pour la Dynamic Island.
@available(iOS 16.2, *)
private struct Rebours: View {
  let parcours: Parcours
  let eta: Date?
  let taille: CGFloat

  var body: some View {
    if parcours.fini {
      Text(parcours.motCourt)
        .font(geist(taille))
        .foregroundColor(menthe)
    } else if let eta, eta > Date() {
      Text(timerInterval: Date()...eta, countsDown: true)
        .font(geist(taille))
        .monospacedDigit()
        .foregroundColor(menthe)
        .multilineTextAlignment(.trailing)
    } else {
      Image(systemName: "clock")
        .font(.system(size: taille, weight: .semibold))
        .foregroundColor(menthe)
    }
  }
}

@available(iOS 16.2, *)
struct TovoOrderWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TovoOrderAttributes.self) { context in
      let p = parcours(context)
      let eta = arrivee(context)
      // ÉCRAN VERROUILLÉ
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Tovo")
              .font(geist(17))
              .foregroundColor(.white)
            Text(p.titre)
              .font(geist(23))
              .foregroundColor(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
              .id(p.titre)
              .transition(.push(from: .bottom))
            Arrivee(parcours: p, eta: eta, taille: 16)
            if eta != nil && !p.fini {
              Text(p.sousTitre)
                .font(geist(13, demiGras: false))
                .foregroundColor(brume)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 8)
          Medaillon(nom: p.image, taille: 66)
            .id(p.image)
            .transition(.scale.combined(with: .opacity))
        }
        Segments(parcours: p)
          .padding(.top, 18)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 20)
      .activityBackgroundTint(Color.black)
      .activitySystemActionForegroundColor(menthe)
    } dynamicIsland: { context in
      let p = parcours(context)
      let eta = arrivee(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Medaillon(nom: p.image, taille: 48)
            .id(p.image)
            .transition(.scale.combined(with: .opacity))
            .padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Rebours(parcours: p, eta: eta, taille: 19)
            .frame(maxWidth: 80, alignment: .trailing)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 3) {
            Text(p.titre)
              .font(geist(16))
              .foregroundColor(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
              .id(p.titre)
              .transition(.push(from: .bottom))
            Text(p.sousTitre)
              .font(geist(12, demiGras: false))
              .foregroundColor(brume)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Segments(parcours: p)
            .padding(.horizontal, 8)
            .padding(.top, 10)
        }
      } compactLeading: {
        Medaillon(nom: p.image, taille: 24, cercle: false)
          .id(p.image)
          .transition(.scale.combined(with: .opacity))
      } compactTrailing: {
        Rebours(parcours: p, eta: eta, taille: 13)
          .frame(maxWidth: 46)
      } minimal: {
        Medaillon(nom: p.image, taille: 22, cercle: false)
      }
      .keylineTint(menthe)
    }
  }

  private func parcours(_ context: ActivityViewContext<TovoOrderAttributes>) -> Parcours {
    Parcours(
      status: context.state.status,
      kind: context.attributes.kind,
      mode: context.attributes.mode ?? "deposer",
      driver: context.state.driver,
      boutique: context.attributes.title
    )
  }

  private func arrivee(_ context: ActivityViewContext<TovoOrderAttributes>) -> Date? {
    guard let secondes = context.attributes.etaAt else { return nil }
    return Date(timeIntervalSince1970: secondes)
  }
}

@main
struct TovoOrderWidgetBundle: WidgetBundle {
  var body: some Widget {
    TovoOrderWidget()
  }
}
