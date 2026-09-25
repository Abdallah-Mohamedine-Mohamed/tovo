import ActivityKit
import Flutter
import UIKit

final class LiveActivityBridge: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var observed = Set<String>()

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "tovo/live_activity", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
    FlutterEventChannel(name: "tovo/live_activity_tokens", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    if #available(iOS 16.2, *) {
      for activity in Activity<TovoOrderAttributes>.activities {
        observe(activity)
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "endAll" {
      if #available(iOS 16.2, *) {
        for activity in Activity<TovoOrderAttributes>.activities {
          Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
      }
      result(true)
      return
    }
    guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
      result(false)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let orderId = args["orderId"] as? String, !orderId.isEmpty else {
      result(FlutterError(code: "invalid_order", message: nil, details: nil))
      return
    }
    let status = args["status"] as? String ?? "pending"
    // Prénom du livreur, dès qu'il existe : l'île dit « Moussa vous l'apporte ».
    let driver = (args["driver"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let existing = Activity<TovoOrderAttributes>.activities.first {
      $0.attributes.orderId == orderId
    }
    // L'heure d'arrivée vient du serveur (push). Une mise à jour faite par
    // l'app, au même statut, ne doit pas l'effacer.
    let precedent = existing?.content.state
    let arrivee = precedent?.status == status ? precedent?.arrivee : nil
    let state = TovoOrderAttributes.ContentState(status: status, driver: driver, arrivee: arrivee)

    switch call.method {
    case "start":
      if let existing {
        observe(existing)
        result(true)
        return
      }
      do {
        let attributes = TovoOrderAttributes(
          orderId: orderId,
          kind: args["kind"] as? String ?? "food",
          title: args["title"] as? String ?? "Votre commande",
          mode: args["mode"] as? String,
          placedAt: (args["placedAt"] as? NSNumber)?.doubleValue,
          etaAt: (args["etaAt"] as? NSNumber)?.doubleValue
        )
        let activity = try Activity.request(
          attributes: attributes,
          content: ActivityContent(state: state, staleDate: nil),
          pushType: .token
        )
        observe(activity)
        result(true)
      } catch {
        result(FlutterError(code: "activity_start_failed", message: error.localizedDescription, details: nil))
      }
    case "sync":
      guard let existing else { result(false); return }
      Task {
        await existing.update(ActivityContent(state: state, staleDate: nil))
      }
      result(true)
    case "end":
      guard let existing else { result(false); return }
      Task {
        await existing.end(
          ActivityContent(state: state, staleDate: nil),
          // Livrée : « Bon appétit ! » reste visible un quart d'heure.
          dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))
        )
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 16.2, *)
  private func observe(_ activity: Activity<TovoOrderAttributes>) {
    if let token = activity.pushToken {
      emit(token, orderId: activity.attributes.orderId)
    }
    guard observed.insert(activity.id).inserted else { return }
    Task {
      for await token in activity.pushTokenUpdates {
        emit(token, orderId: activity.attributes.orderId)
      }
    }
  }

  private func emit(_ token: Data, orderId: String) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(["orderId": orderId, "token": hex])
    }
  }
}
