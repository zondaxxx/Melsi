import Flutter
import Foundation
import NetworkExtension

/// Flutter <-> NETunnelProviderManager bridge (docs/CONTRACT.md §5).
///
/// MethodChannel `app.melsi/vpn`: prepare, start, stop, status, coreVersion,
/// installedApps, appIcon. EventChannel `app.melsi/vpn/events` emits
/// `{"state": "<stopped|connecting|connected|stopping>", "message": String?}`.
///
/// The Runner app does not link libbox: the tunnel runs in the PacketTunnel
/// extension (bundle id `app.melsi.PacketTunnel`); config is handed over via
/// the App Group container `group.app.melsi`.
final class MelsiVpnBridge: NSObject, FlutterStreamHandler {
  static let appGroup = "group.app.melsi"
  static let providerBundleIdentifier = "app.melsi.PacketTunnel"
  static let fallbackCoreVersion = "1.14.2"

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var manager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?
  private var lastState: String = "stopped"
  private var userStopped = false

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: "app.melsi/vpn", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(name: "app.melsi/vpn/events", binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      if let connection = notification.object as? NEVPNConnection,
         let current = self.manager?.connection, connection !== current {
        return
      }
      self.onStatusChanged()
    }
    // Pick up an already-configured manager (and the current tunnel state).
    Task { @MainActor in
      _ = try? await self.loadManager(create: false)
      self.lastState = self.currentState()
      self.emit(self.lastState, message: nil)
    }
  }

  deinit {
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    events(["state": currentState()])
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Method calls

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepare":
      Task { @MainActor in
        do {
          _ = try await self.loadManager(create: true)
          result(true)
        } catch {
          // The user declined the "Add VPN Configurations" prompt.
          result(false)
        }
      }
    case "start":
      guard let args = call.arguments as? [String: Any],
            let config = args["config"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "start expects {config, engine, name}", details: nil))
        return
      }
      let engine = args["engine"] as? String ?? ""
      let name = args["name"] as? String
      Task { @MainActor in
        do {
          try await self.start(config: config, engine: engine, name: name)
          result(nil)
        } catch {
          self.emit("stopped", message: error.localizedDescription)
          result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
        }
      }
    case "stop":
      Task { @MainActor in
        self.userStopped = true
        if self.manager == nil {
          _ = try? await self.loadManager(create: false)
        }
        self.manager?.connection.stopVPNTunnel()
        result(nil)
      }
    case "status":
      Task { @MainActor in
        if self.manager == nil {
          _ = try? await self.loadManager(create: false)
        }
        result(self.currentState())
      }
    case "coreVersion":
      result(coreVersion())
    case "installedApps":
      result([Any]())
    case "appIcon":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Manager

  @MainActor
  private func loadManager(create: Bool) async throws -> NETunnelProviderManager? {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    var manager = managers.first { m in
      (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
    }
    if manager == nil && !create {
      return nil
    }
    let target = manager ?? NETunnelProviderManager()
    var dirty = manager == nil
    let proto = (target.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    if proto.providerBundleIdentifier != Self.providerBundleIdentifier || proto.serverAddress != "Melsi" {
      proto.providerBundleIdentifier = Self.providerBundleIdentifier
      proto.serverAddress = "Melsi"
      dirty = true
    }
    if target.protocolConfiguration !== proto {
      target.protocolConfiguration = proto
      dirty = true
    }
    if target.localizedDescription != "Melsi" {
      target.localizedDescription = "Melsi"
      dirty = true
    }
    if create && !target.isEnabled {
      target.isEnabled = true
      dirty = true
    }
    if dirty && create {
      try await target.saveToPreferences()
      // Required after saving before the connection can be started.
      try await target.loadFromPreferences()
    }
    manager = target
    self.manager = target
    return target
  }

  @MainActor
  private func start(config: String, engine: String, name _: String?) async throws {
    userStopped = false
    // Best effort: the payload also travels in the start options; the files are
    // what on-demand / system restarts and hot reloads use.
    try? writeSharedFile("config.json", config)
    try? writeSharedFile("engine.json", engine)

    guard let manager = try await loadManager(create: true) else {
      throw bridgeError("VPN configuration is not available")
    }
    let connection = manager.connection
    switch connection.status {
    case .connected, .reasserting:
      // Hot reload: the extension re-reads config.json / engine.json.
      if let session = connection as? NETunnelProviderSession {
        try await reload(session)
        return
      }
    case .connecting:
      connection.stopVPNTunnel()
      try await waitForDisconnect(connection)
    case .disconnecting:
      try await waitForDisconnect(connection)
    default:
      break
    }
    lastState = "connecting"
    emit("connecting", message: nil)
    let options: [String: NSObject] = [
      "configContent": config as NSString,
      "engineContent": engine as NSString,
    ]
    try connection.startVPNTunnel(options: options)
  }

  @MainActor
  private func reload(_ session: NETunnelProviderSession) async throws {
    let message = "reload".data(using: .utf8)!
    let response: Data? = try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(message) { data in
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    if let response, !response.isEmpty, let text = String(data: response, encoding: .utf8) {
      throw bridgeError(text)
    }
  }

  @MainActor
  private func waitForDisconnect(_ connection: NEVPNConnection) async throws {
    for _ in 0 ..< 50 {
      if connection.status == .disconnected || connection.status == .invalid {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  // MARK: - Status

  private func currentState() -> String {
    guard let status = manager?.connection.status else {
      return "stopped"
    }
    return Self.mapStatus(status)
  }

  static func mapStatus(_ status: NEVPNStatus) -> String {
    switch status {
    case .connected:
      return "connected"
    case .connecting, .reasserting:
      return "connecting"
    case .disconnecting:
      return "stopping"
    case .disconnected, .invalid:
      return "stopped"
    @unknown default:
      return "stopped"
    }
  }

  private func onStatusChanged() {
    let state = currentState()
    let previous = lastState
    lastState = state
    guard state == "stopped", previous != "stopped", !userStopped else {
      emit(state, message: nil)
      return
    }
    // Unexpected stop: surface the extension's error, if any.
    let fileError = readSharedFile("last_error.txt")
    if #available(iOS 16.0, *), let connection = manager?.connection {
      connection.fetchLastDisconnectError { [weak self] error in
        DispatchQueue.main.async {
          self?.emit(state, message: error?.localizedDescription ?? fileError)
        }
      }
    } else {
      emit(state, message: fileError)
    }
  }

  private func emit(_ state: String, message: String?) {
    guard let eventSink else { return }
    var event: [String: Any] = ["state": state]
    if let message, !message.isEmpty {
      event["message"] = message
    }
    eventSink(event)
  }

  // MARK: - Shared container

  private func sharedDirectory() throws -> URL {
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      throw bridgeError("App Group \(Self.appGroup) is not available (check entitlements / provisioning)")
    }
    return url
  }

  private func writeSharedFile(_ name: String, _ content: String) throws {
    let url = try sharedDirectory().appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  private func readSharedFile(_ name: String) -> String? {
    guard let url = try? sharedDirectory().appendingPathComponent(name) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private func coreVersion() -> String {
    // version.json is written by the extension: {"sing_box": "...", "melsi": "..."}
    if let text = readSharedFile("version.json"),
       let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let version = object["sing_box"] as? String, !version.isEmpty {
      return version
    }
    return Self.fallbackCoreVersion
  }

  private func bridgeError(_ message: String) -> NSError {
    NSError(domain: "app.melsi", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
