import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct TovoOrderWidget: Widget {
  private let teal = Color(red: 0.02, green: 0.37, blue: 0.38)

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TovoOrderAttributes.self) { context in
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("TOVO")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(teal)
          Spacer()
          Text(context.attributes.kind == "courier" ? "Livraison" : "Commande")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Text(label(context.state.status, kind: context.attributes.kind))
          .font(.system(size: 22, weight: .semibold, design: .rounded))
          .foregroundStyle(.primary)
        HStack(spacing: 5) {
          ForEach(0..<4) { stage in
            Capsule()
              .fill(stage <= progress(context.state.status, kind: context.attributes.kind) ? teal : Color.primary.opacity(0.09))
              .frame(height: 4)
          }
        }
      }
      .padding(18)
      .activityBackgroundTint(.white)
      .activitySystemActionForegroundColor(teal)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text("TOVO")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.mint)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Image(systemName: context.attributes.kind == "courier" ? "shippingbox" : "bag")
            .foregroundStyle(.mint)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 12) {
            Text(label(context.state.status, kind: context.attributes.kind))
              .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 5) {
              ForEach(0..<4) { stage in
                Capsule()
                  .fill(stage <= progress(context.state.status, kind: context.attributes.kind) ? Color.mint : Color.white.opacity(0.18))
                  .frame(height: 3)
              }
            }
          }
        }
      } compactLeading: {
        Image(systemName: context.attributes.kind == "courier" ? "shippingbox" : "bag")
          .foregroundStyle(.mint)
      } compactTrailing: {
        Text(shortLabel(context.state.status))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white)
      } minimal: {
        Image(systemName: "bag")
          .foregroundStyle(.mint)
      }
    }
  }

  private func label(_ status: String, kind: String) -> String {
    if status == "cancelled" { return "Commande annulée" }
    if kind == "courier" {
      switch status {
      case "pending", "confirmed", "ready": return "Recherche d’un livreur"
      case "assigned": return "Votre livreur arrive"
      case "picked_up", "delivering": return "Colis en route"
      case "delivered": return "Colis livré"
      default: return "Votre livraison"
      }
    }
    switch status {
    case "pending": return "En attente de confirmation"
    case "confirmed", "preparing": return "En préparation"
    case "ready", "assigned": return "Un livreur arrive"
    case "picked_up", "delivering": return "En route vers vous"
    case "delivered": return "Commande livrée"
    default: return "Votre commande"
    }
  }

  private func shortLabel(_ status: String) -> String {
    switch status {
    case "pending": return "Attente"
    case "confirmed", "preparing": return "Prépare"
    case "ready", "assigned": return "Livreur"
    case "picked_up", "delivering": return "En route"
    case "delivered": return "Livrée"
    default: return "Tovo"
    }
  }

  private func progress(_ status: String, kind: String) -> Int {
    if kind == "courier" {
      switch status {
      case "assigned": return 1
      case "picked_up", "delivering": return 2
      case "delivered": return 3
      default: return 0
      }
    }
    switch status {
    case "confirmed", "preparing": return 1
    case "ready", "assigned": return 2
    case "picked_up", "delivering", "delivered": return 3
    default: return 0
    }
  }
}

@main
struct TovoOrderWidgetBundle: WidgetBundle {
  var body: some Widget {
    TovoOrderWidget()
  }
}
