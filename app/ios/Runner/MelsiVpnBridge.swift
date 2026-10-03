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
  static var packetTunnelBundle: Bundle? {
    guard let plugins = Bundle.main.builtInPlugInsURL,
          let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil),
          let provider = urls.compactMap({ Bundle(url: $0) }).first(where: {
            ($0.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
          }) else {
      return nil
    }
    return provider
  }
  static var providerBundleIdentifier: String { packetTunnelBundle?.bundleIdentifier ?? "app.melsi.PacketTunnel" }
  static let fallbackCoreVersion = "1.14.2"

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var manager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?
  private var lastState: String = "stopped"
  private var userStopped = false
  private var starting = false
  private var lastError: String?
  private var attempt = 0

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
          result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
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
          if !self.userStopped && !(error is CancellationError) {
            self.lastError = error.localizedDescription
            self.emit("error", message: self.lastError)
          }
          result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
        }
      }
    case "stop":
      Task { @MainActor in
        self.userStopped = true
        self.attempt += 1
        self.starting = false
        self.lastError = nil
        if self.manager == nil {
          _ = try? await self.loadManager(create: false)
        }
        do {
          if let connection = self.manager?.connection {
            connection.stopVPNTunnel()
            try await self.waitForDisconnect(connection)
          }
          self.lastState = "stopped"
          self.emit("stopped", message: nil)
          result(nil)
        } catch {
          self.lastError = error.localizedDescription
          self.emit("error", message: self.lastError)
          result(FlutterError(code: "stop_failed", message: self.lastError, details: nil))
        }
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
    if create && Self.packetTunnelBundle == nil {
      throw bridgeError("PacketTunnel extension is missing from this installation. The extension must be embedded and signed together with Melsi.")
    }
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
    }
    if create { try await target.loadFromPreferences() }
    manager = target
    self.manager = target
    return target
  }

  @MainActor
  private func start(config: String, engine: String, name _: String?) async throws {
    userStopped = false
    lastError = nil
    attempt += 1
    let currentAttempt = attempt
    starting = true
    defer { if currentAttempt == attempt { starting = false } }
    // Best effort: the payload also travels in the start options; the files are
    // what on-demand / system restarts and hot reloads use.
    try? writeSharedFile("config.json", config)
    try? writeSharedFile("engine.json", engine)
    try? writeSharedFile("last_error.txt", "")

    guard let manager = try await loadManager(create: true) else {
      throw bridgeError("VPN configuration is not available")
    }
    let connection = manager.connection
    guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
    switch connection.status {
    case .connected, .reasserting:
      // Hot reload: the extension re-reads config.json / engine.json.
      if let session = connection as? NETunnelProviderSession {
        try await reload(session, config: config, engine: engine)
        lastState = "connected"
        emit("connected", message: nil)
        return
      }
    case .connecting:
      if currentAttempt == attempt { connection.stopVPNTunnel() }
      try await waitForDisconnect(connection)
    case .disconnecting:
      try await waitForDisconnect(connection)
    default:
      break
    }
    guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
    lastState = "connecting"
    emit("connecting", message: nil)
    let options: [String: NSObject] = [
      "configContent": config as NSString,
      "engineContent": engine as NSString,
    ]
    try connection.startVPNTunnel(options: options)
    do {
      try await waitForConnection(connection, attempt: currentAttempt)
    } catch {
      if currentAttempt == attempt { connection.stopVPNTunnel() }
      throw error
    }
    lastState = "connected"
    emit("connected", message: nil)
  }

  @MainActor
  private func waitForConnection(_ connection: NEVPNConnection, attempt currentAttempt: Int) async throws {
    var observedStart = false
    for tick in 0 ..< 300 {
      guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
      switch connection.status {
      case .connected:
        return
      case .connecting, .reasserting:
        observedStart = true
      case .disconnected, .invalid:
        if observedStart || tick >= 50 {
          let message = await disconnectMessage(connection)
          throw bridgeError(message
            ?? "iOS could not start the VPN extension. Check the app and PacketTunnel signing and Network Extension entitlements.")
        }
      default:
        break
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw bridgeError("VPN startup timed out after 30 seconds. Check the tunnel log, network access and PacketTunnel signing.")
  }

  @MainActor
  private func disconnectMessage(_ connection: NEVPNConnection) async -> String? {
    let file = readSharedFile("last_error.txt").flatMap { $0.isEmpty ? nil : $0 }
    guard #available(iOS 16.0, *) else { return file }
    return await withCheckedContinuation { continuation in
      var completed = false
      let finish: (String?) -> Void = { message in
        DispatchQueue.main.async {
          guard !completed else { return }
          completed = true
          continuation.resume(returning: message ?? file)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
      connection.fetchLastDisconnectError { finish($0?.localizedDescription) }
    }
  }

  @MainActor
  private func reload(_ session: NETunnelProviderSession, config: String, engine: String) async throws {
    let message = try JSONSerialization.data(withJSONObject: [
      "action": "reload", "configContent": config, "engineContent": engine,
    ])
    let response: Data? = try await withCheckedThrowingContinuation { continuation in
      var completed = false
      let finish: (Result<Data?, Error>) -> Void = { result in
        DispatchQueue.main.async {
          guard !completed else { return }
          completed = true
          continuation.resume(with: result)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        finish(.failure(self.bridgeError("The VPN extension did not respond to reload within 15 seconds.")))
      }
      do {
        try session.sendProviderMessage(message) { data in
          finish(.success(data))
        }
      } catch {
        finish(.failure(error))
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
    throw bridgeError("iOS did not stop the previous VPN session. Try disabling Melsi in Settings > VPN.")
  }

  // MARK: - Status

  private func currentState() -> String {
    guard let status = manager?.connection.status else {
      return "stopped"
    }
    if (status == .disconnected || status == .invalid), lastError != nil { return "error" }
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
    if starting && state == "stopped" { return }
    if state == "error" {
      emit(state, message: lastError)
      return
    }
    let previous = lastState
    lastState = state
    guard state == "stopped", previous != "stopped", !userStopped else {
      emit(state, message: nil)
      return
    }
    // Unexpected stop: surface the extension's error, if any.
    let fileError = readSharedFile("last_error.txt")
    let stoppedAttempt = attempt
    let report: (String?) -> Void = { [weak self] message in
      guard let self, self.attempt == stoppedAttempt, !self.userStopped,
            Self.mapStatus(self.manager?.connection.status ?? .disconnected) == "stopped" else { return }
      self.lastError = message.flatMap { $0.isEmpty ? nil : $0 } ?? "The VPN extension stopped unexpectedly."
      self.lastState = "error"
      self.emit("error", message: self.lastError)
    }
    if #available(iOS 16.0, *), let connection = manager?.connection {
      connection.fetchLastDisconnectError { [weak self] error in
        DispatchQueue.main.async {
          guard self != nil else { return }
          report(error?.localizedDescription ?? fileError)
        }
      }
    } else {
      report(fileError)
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
