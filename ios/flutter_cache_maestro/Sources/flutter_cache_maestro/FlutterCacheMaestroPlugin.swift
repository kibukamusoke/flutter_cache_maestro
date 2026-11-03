import Flutter
import UIKit

/// Native helpers for flutter_cache_maestro. iOS only: keeps the cache
/// directory out of iCloud/iTunes backups (Android uses `no_backup` instead).
public class FlutterCacheMaestroPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_cache_maestro", binaryMessenger: registrar.messenger())
    let instance = FlutterCacheMaestroPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "excludeFromBackup":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "Missing 'path'", details: nil))
        return
      }
      // Excluding a directory also excludes everything inside it.
      var url = URL(fileURLWithPath: path, isDirectory: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(
          FlutterError(
            code: "exclude_failed", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
