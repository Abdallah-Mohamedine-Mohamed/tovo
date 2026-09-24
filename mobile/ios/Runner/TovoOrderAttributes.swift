import ActivityKit

@available(iOS 16.2, *)
struct TovoOrderAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var status: String
  }

  var orderId: String
  var kind: String
  var title: String
}
