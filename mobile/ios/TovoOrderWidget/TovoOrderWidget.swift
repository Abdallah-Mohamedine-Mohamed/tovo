import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// Le suivi de commande sur l'écran verrouillé et dans la Dynamic Island.
//
// TOUT BOUGE, app fermée, sans aucune mise à jour du serveur — c'est le
// système qui fait défiler (retour du client, 25/09 : « je ne veux plus voir
// de temps figé ») :
//   - le TEMPS ÉCOULÉ depuis la commande, en grand, qui tourne à la seconde ;
//   - un ANNEAU autour de l'illustration, qui se remplit à mesure que la
//     course avance (jusqu'à l'heure d'arrivée calculée par le serveur) ;
//   - le segment de l'étape en cours, qui se remplit lui aussi.
// Les étapes arrivent par push APNs ; le titre et l'illustration changent
// alors avec une transition.
//
// iOS n'autorise pas d'animation libre dans une Live Activity (pas de halo
// qui pulse) : seuls les compteurs et les barres liés au temps défilent. On
// s'appuie donc sur eux.

private let menthe = Color(red: 0.37, green: 0.88, blue: 0.77)
private let brume = Color.white.opacity(0.6)
private let eteint = Color.white.opacity(0.22)
private let piste = Color(red: 0.37, green: 0.88, blue: 0.77).opacity(0.16)

/// Geist, embarquée dans le widget (Ressources, déclarée dans Info.plist).
/// Si elle manquait, SwiftUI retomberait sur la police système.
private func geist(_ taille: CGFloat, demiGras: Bool = true) -> Font {
  .custom(demiGras ? "Geist-SemiBold" : "Geist-Medium", size: taille)
}

/// Une illustration 3D du dossier Ressources. La version « -mini » (72 px)
/// sert dans l'île : une image trop lourde y apparaît en carré gris.
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

  /// L'étape en un mot, en haut à droite de la carte.
  var etape: String {
    if annule { return "Annulée" }
    if livre { return colis ? "Livré" : "Livrée" }
    switch index {
    case 0: return colis ? "Recherche" : "Confirmation"
    case 1: return colis ? "Livreur trouvé" : "En cuisine"
    default: return "En route"
    }
  }

  /// La phrase de l'étape. Le prénom du livreur, quand il y en a un, y
  /// figure : il sera mis en menthe.
  var phrase: String {
    if annule { return colis ? "Course annulée" : "Commande annulée" }
    if let nom = driver, !nom.isEmpty {
      switch status {
      case "assigned":
        if colis && !recuperer { return "\(nom) arrive chez vous" }
        return colis ? "\(nom) part chercher le colis" : "\(nom) va chercher votre commande"
      case "picked_up", "delivering":
        return colis && !recuperer ? "\(nom) livre votre colis" : "\(nom) est en route vers vous"
      case "delivered":
        return colis ? "\(nom) a livré, merci !" : "C’est arrivé, bon appétit !"
      default: break
      }
    }
    if colis {
      switch status {
      case "picked_up": return "Colis récupéré"
      case "delivering": return "Colis en route"
      case "delivered": return recuperer ? "Colis remis" : "Colis livré"
      default: return "On cherche un livreur"
      }
    }
    switch status {
    case "pending": return "\(boutique) confirme votre commande"
    case "confirmed": return "Commande acceptée"
    case "preparing": return "Votre repas se prépare, avec soin"
    case "ready": return "Prête, un livreur arrive"
    case "assigned": return "Un livreur va la chercher"
    case "picked_up", "delivering": return "En route vers vous"
    case "delivered": return "C’est arrivé, bon appétit !"
    default: return boutique
    }
  }

  var motCourt: String { annule ? "Annulée" : (colis ? "Livré" : "Livrée") }
}

/// Le temps de la course : depuis la commande, jusqu'à l'arrivée prévue.
@available(iOS 16.2, *)
private struct Chrono {
  let debut: Date
  let fin: Date

  init(_ context: ActivityViewContext<TovoOrderAttributes>, _ p: Parcours) {
    let maintenant = Date()
    let commande = context.attributes.placedAt.map { Date(timeIntervalSince1970: $0) } ?? maintenant
    // L'arrivée calculée par le serveur (livreur en route) ; sinon une durée
    // habituelle, le temps que la cuisine et la route prennent d'ordinaire.
    let prevue = context.state.arrivee.map { Date(timeIntervalSince1970: $0) }
      ?? commande.addingTimeInterval(p.colis ? 25 * 60 : 40 * 60)
    debut = min(commande, maintenant)
    // L'anneau ne doit jamais être plein avant l'arrivée : s'il reste moins
    // d'une minute, on lui en laisse une.
    fin = max(prevue, maintenant.addingTimeInterval(60), debut.addingTimeInterval(60))
  }

  /// Ce que l'anneau et les segments parcourent.
  var parcours: ClosedRange<Date> { debut...fin }

  /// Le temps écoulé tourne jusqu'à 12 h : largement assez pour une course.
  var ecoule: ClosedRange<Date> { debut...debut.addingTimeInterval(12 * 3600) }
}

/// Le temps écoulé depuis la commande, qui tourne à la seconde.
@available(iOS 16.2, *)
private struct TempsEcoule: View {
  let chrono: Chrono
  let taille: CGFloat
  var couleur: Color = .white
  var largeur: CGFloat

  var body: some View {
    Text(timerInterval: chrono.ecoule, countsDown: false)
      .font(geist(taille))
      .monospacedDigit()
      .foregroundColor(couleur)
      // Un compteur prend toute la largeur qu'on lui laisse : on la borne.
      .frame(maxWidth: largeur, alignment: .leading)
  }
}

/// L'illustration dans un anneau qui se remplit avec le temps.
@available(iOS 16.2, *)
private struct Anneau: View {
  let nom: String
  let taille: CGFloat
  let chrono: Chrono
  let fini: Bool
  var mini = false

  private var trait: CGFloat { max(2, taille / 15) }

  var body: some View {
    ZStack {
      Circle().fill(Color.white.opacity(0.07))
      if fini {
        Circle().stroke(menthe, lineWidth: trait)
      } else {
        Circle().stroke(piste, lineWidth: trait)
        ProgressView(
          timerInterval: chrono.parcours,
          countsDown: false,
          label: { EmptyView() },
          currentValueLabel: { EmptyView() }
        )
        .progressViewStyle(.circular)
        .tint(menthe)
        .frame(width: taille, height: taille)
      }
      if let image = illustration(mini ? "\(nom)-mini" : nom) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .padding(taille * (mini ? 0.2 : 0.17))
      }
    }
    .frame(width: taille, height: taille)
  }
}

/// Les segments : faits en menthe ; celui de l'étape en cours se remplit
/// avec le temps ; les suivants attendent, à peine teintés.
@available(iOS 16.2, *)
private struct Segments: View {
  let parcours: Parcours
  let chrono: Chrono

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<parcours.segments, id: \.self) { i in
        segment(i)
      }
    }
  }

  @ViewBuilder
  private func segment(_ i: Int) -> some View {
    if parcours.annule {
      Capsule().fill(eteint).frame(height: 5)
    } else if i < parcours.index || parcours.livre {
      Capsule().fill(menthe).frame(height: 5)
    } else if i == parcours.index {
      ProgressView(
        timerInterval: chrono.parcours,
        countsDown: false,
        label: { EmptyView() },
        currentValueLabel: { EmptyView() }
      )
      .progressViewStyle(.linear)
      .tint(menthe)
      .background(Capsule().fill(piste))
      .frame(height: 5)
      .clipShape(Capsule())
    } else {
      Capsule().fill(piste).frame(height: 5)
    }
  }
}

/// La phrase, le prénom du livreur en menthe.
@available(iOS 16.2, *)
private func phrase(_ p: Parcours) -> Text {
  let texte = p.phrase
  guard let nom = p.driver, !nom.isEmpty, let r = texte.range(of: nom) else {
    return Text(texte).foregroundColor(.white)
  }
  return Text(String(texte[..<r.lowerBound])).foregroundColor(.white)
    + Text(nom).foregroundColor(menthe)
    + Text(String(texte[r.upperBound...])).foregroundColor(.white)
}

@available(iOS 16.2, *)
struct TovoOrderWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TovoOrderAttributes.self) { context in
      let p = parcours(context)
      let c = Chrono(context, p)
      // ÉCRAN VERROUILLÉ
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Tovo")
            .font(geist(15))
            .foregroundColor(.white)
          Spacer()
          Text(p.etape)
            .font(geist(13, demiGras: false))
            .foregroundColor(p.annule ? brume : menthe)
            .id(p.etape)
            .transition(.opacity)
        }
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            phrase(p)
              .font(geist(18))
              .lineLimit(2)
              .minimumScaleFactor(0.8)
              .id(p.phrase)
              .transition(.push(from: .bottom))
            if p.fini {
              Text(p.livre ? "Merci d’avoir choisi Tovo." : "Vous pouvez recommander quand vous voulez.")
                .font(geist(13, demiGras: false))
                .foregroundColor(brume)
                .lineLimit(1)
            } else {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                TempsEcoule(chrono: c, taille: 40, largeur: 150)
                  .fixedSize(horizontal: false, vertical: true)
                Text("depuis la commande")
                  .font(geist(13, demiGras: false))
                  .foregroundColor(brume)
                  .lineLimit(1)
              }
            }
          }
          Spacer(minLength: 6)
          Anneau(nom: p.image, taille: 70, chrono: c, fini: p.fini)
            .id(p.image)
            .transition(.scale.combined(with: .opacity))
        }
        Segments(parcours: p, chrono: c)
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)
      .padding(.bottom, 18)
      .activityBackgroundTint(Color.black.opacity(0.82))
      .activitySystemActionForegroundColor(menthe)
    } dynamicIsland: { context in
      let p = parcours(context)
      let c = Chrono(context, p)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Anneau(nom: p.image, taille: 52, chrono: c, fini: p.fini)
            .id(p.image)
            .transition(.scale.combined(with: .opacity))
            .padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 0) {
            if p.fini {
              Text(p.motCourt)
                .font(geist(18))
                .foregroundColor(menthe)
            } else {
              Text(timerInterval: c.ecoule, countsDown: false)
                .font(geist(24))
                .monospacedDigit()
                .foregroundColor(menthe)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 88, alignment: .trailing)
              Text("écoulées")
                .font(geist(11, demiGras: false))
                .foregroundColor(brume)
            }
          }
          .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          phrase(p)
            .font(geist(15))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(p.phrase)
            .transition(.push(from: .bottom))
        }
        DynamicIslandExpandedRegion(.bottom) {
          Segments(parcours: p, chrono: c)
            .padding(.horizontal, 8)
            .padding(.top, 10)
        }
      } compactLeading: {
        Anneau(nom: p.image, taille: 26, chrono: c, fini: p.fini, mini: true)
          .id(p.image)
          .transition(.scale.combined(with: .opacity))
      } compactTrailing: {
        if p.fini {
          Text(p.motCourt)
            .font(geist(13))
            .foregroundColor(menthe)
        } else {
          Text(timerInterval: c.ecoule, countsDown: false)
            .font(geist(14))
            .monospacedDigit()
            .foregroundColor(menthe)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 50)
        }
      } minimal: {
        Anneau(nom: p.image, taille: 24, chrono: c, fini: p.fini, mini: true)
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
}

@main
struct TovoOrderWidgetBundle: WidgetBundle {
  var body: some Widget {
    TovoOrderWidget()
  }
}
