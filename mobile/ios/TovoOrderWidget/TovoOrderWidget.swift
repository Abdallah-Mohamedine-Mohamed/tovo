import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// Le suivi de commande sur l'écran verrouillé et dans la Dynamic Island.
//
// CE QUI BOUGE, app fermée, sans aucune mise à jour du serveur — c'est le
// système qui fait défiler :
//   - le temps écoulé depuis la commande (« 12:34 min »), à la seconde ;
//   - le segment de l'étape en cours, qui se remplit à mesure que la course
//     avance (jusqu'à l'arrivée calculée par le serveur).
// Les étapes arrivent par push APNs : la phrase, l'étape et l'illustration
// changent alors avec une transition.
//
// LA PHRASE s'adresse au client par son prénom, au début ou à la fin
// (« Awa, votre commande est confirmée », « Bon appétit, Awa ! »), et nomme
// le livreur en menthe. L'étape, en haut à droite, dit où l'on en est en
// mots simples (« Colis récupéré », « En cuisine »).
//
// DANS L'ÎLE, les illustrations sont posées telles quelles, grandes, sans
// cercle autour ; sur l'écran verrouillé, elles gardent leur médaillon.

private let menthe = Color(red: 0.37, green: 0.88, blue: 0.77)
private let brume = Color.white.opacity(0.6)
private let eteint = Color.white.opacity(0.22)
private let piste = Color(red: 0.37, green: 0.88, blue: 0.77).opacity(0.16)

/// Geist, embarquée dans le widget (Ressources, déclarée dans Info.plist).
/// Si elle manquait, SwiftUI retomberait sur la police système.
private func geist(_ taille: CGFloat, demiGras: Bool = true) -> Font {
  .custom(demiGras ? "Geist-SemiBold" : "Geist-Medium", size: taille)
}

/// Une illustration 3D du dossier Ressources. La version « -mini » (96 px)
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
  let client: String?
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

  /// L'étape, en mots simples.
  var etape: String {
    if annule { return "Annulée" }
    if colis {
      switch status {
      case "assigned": return recuperer ? "Vers votre colis" : "Livreur en chemin"
      case "picked_up": return "Colis récupéré"
      case "delivering": return "Colis en route"
      case "delivered": return recuperer ? "Colis remis" : "Colis livré"
      default: return "Recherche d’un livreur"
      }
    }
    switch status {
    case "pending": return "Envoyée"
    case "confirmed": return "Confirmée"
    case "preparing": return "En cuisine"
    case "ready": return "Prête"
    case "assigned": return "Livreur trouvé"
    case "picked_up": return "Récupérée"
    case "delivering": return "En route"
    case "delivered": return "Livrée"
    default: return "En cours"
    }
  }

  /// La phrase de l'étape, qui s'adresse au client par son prénom — au début
  /// (« Awa, … ») ou à la fin (« …, Awa ») selon l'étape, pour que ça sonne
  /// juste. Sans prénom connu, la phrase s'en passe.
  var phrase: String {
    let livreur = (driver?.isEmpty == false) ? driver! : "Votre livreur"
    func debut(_ texte: String) -> String {
      guard let c = client, !c.isEmpty else { return majuscule(texte) }
      return "\(c), \(texte)"
    }
    func fin(_ texte: String, _ ponctuation: String = "") -> String {
      guard let c = client, !c.isEmpty else { return texte + ponctuation }
      return "\(texte), \(c)\(ponctuation)"
    }
    if annule { return debut(colis ? "votre course est annulée" : "votre commande est annulée") }
    if colis {
      switch status {
      case "assigned":
        return recuperer
          ? fin("\(livreur) part chercher votre colis")
          : fin("\(livreur) arrive chercher votre colis")
      case "picked_up":
        return recuperer ? debut("\(livreur) a récupéré votre colis") : fin("Colis récupéré", " !")
      case "delivering":
        return recuperer ? fin("Votre colis arrive") : debut("votre colis est en route")
      case "delivered":
        return fin(recuperer ? "Colis remis, merci" : "Colis livré, merci", " !")
      default:
        return debut("on vous trouve un livreur")
      }
    }
    switch status {
    case "pending": return debut("\(boutique) confirme votre commande")
    case "confirmed": return debut("votre commande est confirmée")
    case "preparing": return fin("Votre repas se prépare")
    case "ready": return debut("votre commande est prête")
    case "assigned": return fin("\(livreur) va chercher votre commande")
    case "picked_up", "delivering": return debut("\(livreur) arrive avec votre commande")
    case "delivered": return fin("Bon appétit", " !")
    default: return fin("Votre commande est en cours")
    }
  }

  var motCourt: String { annule ? "Annulée" : (colis ? "Livré" : "Livrée") }
}

private func majuscule(_ texte: String) -> String {
  guard let premiere = texte.first else { return texte }
  return premiere.uppercased() + texte.dropFirst()
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
    // La barre ne doit jamais être pleine avant l'arrivée.
    fin = max(prevue, maintenant.addingTimeInterval(60), debut.addingTimeInterval(60))
  }

  /// Ce que le segment de l'étape en cours parcourt.
  var parcours: ClosedRange<Date> { debut...fin }

  /// La part de la course déjà faite, de 0 à 1, à l'instant du rendu.
  var fait: Double {
    let total = fin.timeIntervalSince(debut)
    guard total > 0 else { return 0 }
    return min(1, max(0.03, Date().timeIntervalSince(debut) / total))
  }

  /// Le temps écoulé tourne jusqu'à 12 h : largement assez pour une course.
  var ecoule: ClosedRange<Date> { debut...debut.addingTimeInterval(12 * 3600) }
}

/// L'illustration dans son médaillon, pour l'écran verrouillé, entourée d'un
/// anneau menthe qui dit où en est la course.
///
/// L'anneau est DESSINÉ (un arc net, bouts arrondis) plutôt que confié au
/// ProgressView circulaire du système : celui-ci, étiré à la taille du
/// médaillon, sortait flou. Il avance à chaque mise à jour de la course ; le
/// segment de l'étape, en bas, défile lui en continu.
@available(iOS 16.2, *)
private struct Medaillon: View {
  let nom: String
  let taille: CGFloat
  /// De 0 à 1 ; nil : pas d'anneau (course finie ou annulée).
  var fait: Double?
  var annule = false

  private var trait: CGFloat { max(3, taille / 18) }

  var body: some View {
    ZStack {
      Circle().fill(Color.white.opacity(0.08))
      if let fait {
        Circle().stroke(piste, lineWidth: trait)
        Circle()
          .trim(from: 0, to: fait)
          .stroke(menthe, style: StrokeStyle(lineWidth: trait, lineCap: .round))
          .rotationEffect(.degrees(-90))
      } else {
        Circle().stroke(annule ? eteint : menthe, lineWidth: trait)
      }
      if let image = illustration(nom) {
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(taille * 0.17)
      }
    }
    .padding(trait / 2)
    .frame(width: taille, height: taille)
  }
}

/// L'illustration seule, grande, sans cercle — pour la Dynamic Island.
@available(iOS 16.2, *)
private struct Icone: View {
  let nom: String
  let taille: CGFloat
  var mini = true

  var body: some View {
    Group {
      if let image = illustration(mini ? "\(nom)-mini" : nom) {
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Color.clear
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

/// « 12:34 min » : le temps écoulé, qui tourne, et son unité.
@available(iOS 16.2, *)
private struct TempsEcoule: View {
  let chrono: Chrono
  let taille: CGFloat
  let largeur: CGFloat
  var suite = "min"

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(timerInterval: chrono.ecoule, countsDown: false)
        .font(geist(taille))
        .monospacedDigit()
        .foregroundColor(menthe)
        // Un compteur prend toute la largeur qu'on lui laisse : on la borne.
        .frame(maxWidth: largeur, alignment: .leading)
      Text(suite)
        .font(geist(taille * 0.8, demiGras: false))
        .foregroundColor(brume)
        .lineLimit(1)
    }
  }
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
            .font(geist(13))
            .foregroundColor(p.annule ? brume : menthe)
            .id(p.etape)
            .transition(.opacity)
        }
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            phrase(p)
              .font(geist(19))
              .lineLimit(2)
              .minimumScaleFactor(0.8)
              .fixedSize(horizontal: false, vertical: true)
              .id(p.phrase)
              .transition(.push(from: .bottom))
            if p.fini {
              Text(p.livre ? "Merci d’avoir choisi Tovo." : "Vous pouvez recommander quand vous voulez.")
                .font(geist(13, demiGras: false))
                .foregroundColor(brume)
                .lineLimit(1)
            } else {
              TempsEcoule(chrono: c, taille: 16, largeur: 64, suite: "min depuis la commande")
            }
          }
          Spacer(minLength: 6)
          Medaillon(nom: p.image, taille: 66, fait: p.fini ? nil : c.fait, annule: p.annule)
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
          Icone(nom: p.image, taille: 58, mini: false)
            .id(p.image)
            .transition(.scale.combined(with: .opacity))
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 1) {
            if p.fini {
              Text(p.motCourt)
                .font(geist(18))
                .foregroundColor(menthe)
            } else {
              Text(timerInterval: c.ecoule, countsDown: false)
                .font(geist(22))
                .monospacedDigit()
                .foregroundColor(menthe)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 84, alignment: .trailing)
            }
          }
          .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 3) {
            Text(p.etape)
              .font(geist(12))
              .foregroundColor(p.annule ? brume : menthe)
            phrase(p)
              .font(geist(15))
              .lineLimit(2)
              .minimumScaleFactor(0.8)
          }
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
        Icone(nom: p.image, taille: 30)
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
            .frame(maxWidth: 46)
        }
      } minimal: {
        Icone(nom: p.image, taille: 26)
      }
      // Un liseré à peine visible : l'île reste noire, discrète.
      .keylineTint(menthe.opacity(0.28))
    }
  }

  private func parcours(_ context: ActivityViewContext<TovoOrderAttributes>) -> Parcours {
    Parcours(
      status: context.state.status,
      kind: context.attributes.kind,
      mode: context.attributes.mode ?? "deposer",
      driver: context.state.driver,
      client: context.attributes.client,
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
