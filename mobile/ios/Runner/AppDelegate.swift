import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var liveActivityBridge: LiveActivityBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Carte de suivi. La clé est inscrite dans Info.plist (GMSApiKey) par
    // Codemagic au moment du build, depuis ses variables : jamais dans le
    // dépôt. Absente, la carte reste grise mais l'app fonctionne.
    if let cle = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
       !cle.isEmpty {
      GMSServices.provideAPIKey(cle)
    }
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      liveActivityBridge = LiveActivityBridge(messenger: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
