import ActivityKit
import SwiftUI
import WidgetKit

// Le suivi de commande sur l'écran verrouillé et dans la Dynamic Island.
//
// Ce qu'on veut qu'on regarde : un scooter qui avance sur une piste à chaque
// étape, un chronomètre qui défile tout seul (sans mise à jour du serveur),
// l'icône de l'étape en cours dans l'île, le prénom du livreur dès qu'il
// existe, et « Bon appétit ! » à la fin d'un repas.
//
// Fond encre, accent menthe : la palette de Tovo, sobre, lisible le jour
// comme la nuit (l'ancien fond blanc devenait illisible en mode sombre).

private let encre = Color(red: 0.078, green: 0.125, blue: 0.118)    // #14201E
private let menthe = Color(red: 0.42, green: 0.86, blue: 0.76)      // accent vif
private let brume = Color.white.opacity(0.62)
private let piste = Color.white.opacity(0.16)

private struct Etape {
  let icone: String
  let nom: String
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

  var etapes: [Etape] {
    if !colis {
      return [
        Etape(icone: "bag.fill", nom: "Acceptée"),
        Etape(icone: "frying.pan.fill", nom: "En cuisine"),
        Etape(icone: "scooter", nom: "En route"),
        Etape(icone: "house.fill", nom: "Livrée"),
      ]
    }
    return [
      Etape(icone: "magnifyingglass", nom: "Livreur"),
      Etape(icone: "scooter", nom: recuperer ? "Il y va" : "Il arrive"),
      Etape(icone: "shippingbox.fill", nom: "Récupéré"),
      Etape(icone: recuperer ? "house.fill" : "flag.fill", nom: "Livré"),
    ]
  }

  /// L'étape en cours, de 0 à 3.
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
      case "confirmed", "preparing", "ready", "assigned": return 1
      case "picked_up", "delivering": return 2
      case "delivered": return 3
      default: return 0
    }
  }

  /// Où en est le scooter sur la piste. Chaque statut le fait avancer, même
  /// quand l'étape affichée ne change pas : on voit que ça bouge.
  var avancee: Double {
    if colis {
      switch status {
      case "assigned": return 0.36
      case "picked_up": return 0.66
      case "delivering": return 0.82
      case "delivered": return 1.0
      default: return 0.08
      }
    }
    switch status {
    case "pending": return 0.06
    case "confirmed": return 0.22
    case "preparing": return 0.38
    case "ready": return 0.5
    case "assigned": return 0.56
    case "picked_up": return 0.7
    case "delivering": return 0.84
    case "delivered": return 1.0
    default: return 0.06
    }
  }

  var icone: String {
    if annule { return "xmark" }
    if livre { return colis ? "checkmark" : "fork.knife" }
    return etapes[index].icone
  }

  var titre: String {
    if annule { return colis ? "Course annulée" : "Commande annulée" }
    if colis {
      switch status {
      case "assigned": return recuperer ? "Il part chercher le colis" : "Votre livreur arrive"
      case "picked_up": return "Colis récupéré"
      case "delivering": return recuperer ? "Votre colis arrive" : "En route vers la destination"
      case "delivered": return recuperer ? "Colis remis" : "Colis livré"
      default: return "On cherche un livreur"
      }
    }
    switch status {
    case "pending": return "La boutique confirme"
    case "confirmed": return "Commande acceptée"
    case "preparing": return "En cuisine"
    case "ready": return "Prête, un livreur arrive"
    case "assigned": return "Un livreur va la chercher"
    case "picked_up": return "Récupérée, en route"
    case "delivering": return "En route vers vous"
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

  /// Le mot court de la Dynamic Island, quand le chronomètre n'a plus de sens.
  var motCourt: String {
    if annule { return "Annulée" }
    return colis ? "Livré" : "Livrée"
  }
}

// La piste : un trait qui se remplit, et le véhicule en tête.
@available(iOS 16.2, *)
private struct Piste: View {
  let avancee: Double
  let icone: String
  let couleur: Color

  var body: some View {
    GeometryReader { geo in
      let largeur = geo.size.width
      let x = largeur * CGFloat(min(max(avancee, 0), 1))
      ZStack(alignment: .leading) {
        Capsule().fill(piste).frame(height: 6)
        Capsule().fill(couleur).frame(width: max(6, x), height: 6)
        ZStack {
          Circle().fill(couleur)
          Image(systemName: icone)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(encre)
        }
        .frame(width: 26, height: 26)
        .offset(x: min(max(0, x - 13), largeur - 26))
      }
      .frame(height: 26)
    }
    .frame(height: 26)
  }
}

// Les quatre étapes sous la piste : faites en blanc, en cours en menthe.
@available(iOS 16.2, *)
private struct Etapes: View {
  let parcours: Parcours

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(parcours.etapes.enumerated()), id: \.offset) { position, etape in
        Text(etape.nom)
          .font(.system(size: 11, weight: position == parcours.index ? .bold : .medium))
          .foregroundColor(
            position == parcours.index ? menthe : (position < parcours.index ? .white : brume)
          )
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxWidth: .infinity, alignment: alignement(position))
      }
    }
  }

  private func alignement(_ position: Int) -> Alignment {
    if position == 0 { return .leading }
    if position == parcours.etapes.count - 1 { return .trailing }
    return .center
  }
}

// Le temps écoulé depuis la commande. Il défile tout seul (le système le
// met à jour chaque seconde) ; il s'arrête sur une coche une fois fini.
@available(iOS 16.2, *)
private struct Chrono: View {
  let depuis: Date?
  let parcours: Parcours
  let taille: CGFloat

  var body: some View {
    if parcours.fini {
      Image(systemName: parcours.annule ? "xmark.circle.fill" : "checkmark.circle.fill")
        .font(.system(size: taille, weight: .semibold))
        .foregroundColor(menthe)
    } else if let depuis {
      Text(depuis, style: .timer)
        .font(.system(size: taille, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundColor(.white)
        .multilineTextAlignment(.trailing)
    }
  }
}

@available(iOS 16.2, *)
struct TovoOrderWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TovoOrderAttributes.self) { context in
      let p = parcours(context)
      let depuis = date(context)
      // ÉCRAN VERROUILLÉ
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Text("tovo")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundColor(menthe)
          Text(context.attributes.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(brume)
            .lineLimit(1)
          Spacer(minLength: 8)
          Chrono(depuis: depuis, parcours: p, taille: 15)
            .frame(maxWidth: 70, alignment: .trailing)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(p.titre)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Text(p.sousTitre)
            .font(.system(size: 14))
            .foregroundColor(brume)
            .lineLimit(1)
        }
        if !p.annule {
          Piste(avancee: p.avancee, icone: p.icone, couleur: menthe)
          Etapes(parcours: p)
        }
      }
      .padding(18)
      .activityBackgroundTint(encre)
      .activitySystemActionForegroundColor(menthe)
    } dynamicIsland: { context in
      let p = parcours(context)
      let depuis = date(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          ZStack {
            Circle().fill(menthe)
            Image(systemName: p.icone)
              .font(.system(size: 17, weight: .bold))
              .foregroundColor(encre)
          }
          .frame(width: 40, height: 40)
          .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Chrono(depuis: depuis, parcours: p, taille: 17)
            .frame(maxWidth: 76, alignment: .trailing)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(p.titre)
              .font(.system(size: 16, weight: .bold, design: .rounded))
              .foregroundColor(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            Text(p.sousTitre)
              .font(.system(size: 12))
              .foregroundColor(brume)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if !p.annule {
            VStack(spacing: 8) {
              Piste(avancee: p.avancee, icone: p.icone, couleur: menthe)
              Etapes(parcours: p)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
          }
        }
      } compactLeading: {
        Image(systemName: p.icone)
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(menthe)
      } compactTrailing: {
        if p.fini {
          Text(p.motCourt)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(menthe)
        } else if let depuis {
          Text(depuis, style: .timer)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 44)
        } else {
          Text(p.titre)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .frame(maxWidth: 70)
        }
      } minimal: {
        Image(systemName: p.icone)
          .font(.system(size: 13, weight: .bold))
          .foregroundColor(menthe)
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

  private func date(_ context: ActivityViewContext<TovoOrderAttributes>) -> Date? {
    guard let secondes = context.attributes.placedAt else { return nil }
    return Date(timeIntervalSince1970: secondes)
  }
}

@main
struct TovoOrderWidgetBundle: WidgetBundle {
  var body: some Widget {
    TovoOrderWidget()
  }
}
