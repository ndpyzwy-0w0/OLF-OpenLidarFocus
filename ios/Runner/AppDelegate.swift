import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LidarPlugin")!
    LidarPlugin.register(with: registrar)

    // 功能层：跟焦逻辑和镜头存档都由它持有，UI 只通过 `ff.core` 通道读写。
    let core = engineBridge.pluginRegistry.registrar(forPlugin: "FollowFocusCorePlugin")!
    FollowFocusCorePlugin.register(with: core)
  }
}
