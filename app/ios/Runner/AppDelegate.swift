import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let nativeBridgeRegistry = NativeBridgeRegistry()
  private let backgroundTaskHostApi = BackgroundTaskHostApiAdapter()
  private var agentTraceLogChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    backgroundTaskHostApi.registerScheduler()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "NativeBridgeRegistry"
    ) else {
      return
    }
    let messenger = registrar.messenger()
    nativeBridgeRegistry.register(with: messenger)
    let channel = FlutterMethodChannel(
      name: "com.gemmalocal.gemmaLocal/agent_trace_log",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "log" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let args = call.arguments as? [String: Any],
         let line = args["line"] as? String {
        NSLog("%@", line)
      }
      result(nil)
    }
    agentTraceLogChannel = channel
  }
}
