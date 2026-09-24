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
    guard let args = call.arguments as? [String: String],
          let orderId = args["orderId"], !orderId.isEmpty else {
      result(FlutterError(code: "invalid_order", message: nil, details: nil))
      return
    }
    let status = args["status"] ?? "pending"
    let existing = Activity<TovoOrderAttributes>.activities.first {
      $0.attributes.orderId == orderId
    }

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
          kind: args["kind"] ?? "food",
          title: args["title"] ?? "Votre commande"
        )
        let activity = try Activity.request(
          attributes: attributes,
          content: ActivityContent(state: .init(status: status), staleDate: nil),
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
        await existing.update(ActivityContent(state: .init(status: status), staleDate: nil))
      }
      result(true)
    case "end":
      guard let existing else { result(false); return }
      Task {
        await existing.end(
          ActivityContent(state: .init(status: status), staleDate: nil),
          dismissalPolicy: .after(Date().addingTimeInterval(60))
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
