import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// Le suivi de commande sur l'écran verrouillé et dans la Dynamic Island,
// dans l'esprit d'Uber Eats : fond noir, « Tovo » bien lisible, un grand
// titre, le temps, une illustration 3D ronde qui change à chaque étape, et
// des segments espacés en bas. Le titre et l'illustration s'animent à
// chaque étape.
//
// LE TEMPS (décision du client, 25/09) :
//   - tant qu'aucun livreur n'est en route, le temps ÉCOULÉ depuis la
//     commande (« Depuis 6:12 ») : honnête, il ne se trompe jamais ;
//   - dès qu'un livreur est en route, une HEURE d'arrivée (« Arrivée vers
//     14:35 »), calculée par le serveur sur les vraies distances. Une heure
//     ne défile pas vers zéro sous les yeux du client : elle ne peut pas
//     « rater » son rendez-vous, et se corrige sans bruit à chaque étape.
// Le temps écoulé défile SANS mise à jour : c'est le système qui compte.
// Les étapes et l'heure arrivent par push APNs, app fermée.

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

/// Le temps d'une course : l'heure d'arrivée si un livreur est en route,
/// sinon le temps écoulé depuis la commande.
@available(iOS 16.2, *)
private struct Temps {
  let parcours: Parcours
  /// Heure d'arrivée envoyée par le serveur.
  let arrivee: Date?
  /// Heure de la commande.
  let depuis: Date?

  var enRoute: Bool { ["assigned", "picked_up", "delivering"].contains(parcours.status) }

  /// L'heure d'arrivée, seulement si elle a encore un sens : un livreur en
  /// route, et une heure qui n'est pas dépassée de plus de 5 minutes.
  var heure: Date? {
    guard enRoute, let arrivee, arrivee > Date().addingTimeInterval(-5 * 60) else { return nil }
    return arrivee
  }

  /// Le temps écoulé défile jusqu'à 12 h : largement assez pour une course.
  var ecoule: ClosedRange<Date>? {
    guard let depuis, depuis <= Date() else { return nil }
    return depuis...depuis.addingTimeInterval(12 * 3600)
  }
}

/// La ligne du temps, sur l'écran verrouillé : « Arrivée vers 14:35 », ou
/// « Depuis 6:12 » ; sinon la phrase de l'étape.
@available(iOS 16.2, *)
private struct LigneTemps: View {
  let temps: Temps
  let taille: CGFloat

  var body: some View {
    Group {
      if temps.parcours.fini {
        Text(temps.parcours.sousTitre).foregroundColor(brume)
      } else if let heure = temps.heure {
        Text("Arrivée vers ").foregroundColor(brume)
          + Text(heure, style: .time).foregroundColor(menthe)
      } else if let ecoule = temps.ecoule {
        Text("Depuis ").foregroundColor(brume)
          + Text(timerInterval: ecoule, countsDown: false).foregroundColor(menthe)
      } else {
        Text(temps.parcours.sousTitre).foregroundColor(brume)
      }
    }
    .font(geist(taille, demiGras: false))
    .monospacedDigit()
    .lineLimit(1)
  }
}

/// Le temps seul, pour la Dynamic Island : « 14:35 » (arrivée) ou « 6:12 »
/// (écoulé).
@available(iOS 16.2, *)
private struct TempsCourt: View {
  let temps: Temps
  let taille: CGFloat

  var body: some View {
    if temps.parcours.fini {
      Text(temps.parcours.motCourt)
        .font(geist(taille))
        .foregroundColor(menthe)
    } else if let heure = temps.heure {
      Text(heure, style: .time)
        .font(geist(taille))
        .monospacedDigit()
        .foregroundColor(menthe)
        .multilineTextAlignment(.trailing)
    } else if let ecoule = temps.ecoule {
      Text(timerInterval: ecoule, countsDown: false)
        .font(geist(taille))
        .monospacedDigit()
        .foregroundColor(brume)
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
      let t = temps(context, p)
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
            LigneTemps(temps: t, taille: 16)
            // La phrase de l'étape, sous le temps (quand le temps l'a
            // remplacée sur la ligne du dessus).
            if !p.fini && (t.heure != nil || t.ecoule != nil) {
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
      let t = temps(context, p)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Medaillon(nom: p.image, taille: 48)
            .id(p.image)
            .transition(.scale.combined(with: .opacity))
            .padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          TempsCourt(temps: t, taille: 19)
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
        TempsCourt(temps: t, taille: 13)
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

  private func temps(_ context: ActivityViewContext<TovoOrderAttributes>, _ p: Parcours) -> Temps {
    Temps(
      parcours: p,
      arrivee: context.state.arrivee.map { Date(timeIntervalSince1970: $0) },
      depuis: context.attributes.placedAt.map { Date(timeIntervalSince1970: $0) }
    )
  }
}

@main
struct TovoOrderWidgetBundle: WidgetBundle {
  var body: some Widget {
    TovoOrderWidget()
  }
}
