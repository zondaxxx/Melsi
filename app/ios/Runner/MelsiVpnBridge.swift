import Flutter
import Foundation
import NetworkExtension
import UIKit

/// Flutter <-> NETunnelProviderManager bridge (docs/CONTRACT.md §5).
///
/// MethodChannel `app.melsi/vpn`: prepare, start, stop, status, coreVersion,
/// installedApps, appIcon. EventChannel `app.melsi/vpn/events` emits
/// `{"state": "<stopped|connecting|connected|stopping>", "message": String?}`.
///
/// The Runner app does not link libbox: the tunnel runs in the PacketTunnel
/// extension (bundle id `app.melsi.PacketTunnel`). Config is handed over via
/// an App Group container. Official builds use `group.app.melsi`; a re-signed
/// build uses the first writable group shared by the app and the extension.
final class MelsiVpnBridge: NSObject, FlutterStreamHandler {
  static let preferredAppGroup = TunnelConfiguration.preferredAppGroup
  private var cachedContainer: TunnelConfiguration.SharedContainer?
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
  private var activeObserver: NSObjectProtocol?
  private var lastState: String = "stopped"
  private var userStopped = false
  private var starting = false
  private var lastError: String?
  private var attempt = 0
  private var recoveryWarning: String?
  private let preferences = TunnelPreferenceQueue()

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
    activeObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.refreshStatus() }
    }
    // Pick up an already-configured manager (and the current tunnel state).
    Task { @MainActor in
      _ = try? await self.loadManager(create: false)
      self.onStatusChanged()
    }
  }

  deinit {
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
    if let activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    let state = currentState()
    emit(state, message: state == "error" ? lastError : nil)
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
        let stopAttempt = self.attempt
        self.starting = false
        self.lastError = nil
        self.recoveryWarning = nil
        if self.manager == nil {
          _ = try? await self.loadManager(create: false)
        }
        do {
          guard stopAttempt == self.attempt, self.userStopped else { throw CancellationError() }
          if let connection = self.manager?.connection {
            // Persist the stop intent before stopping the live provider, so
            // the system cannot restart it on the next network request.
            try await self.setRecoveryEnabled(false, attempt: stopAttempt)
            guard stopAttempt == self.attempt, self.userStopped else { throw CancellationError() }
            connection.stopVPNTunnel()
            try await self.waitForDisconnect(connection, attempt: stopAttempt)
          }
          guard stopAttempt == self.attempt, self.userStopped else { throw CancellationError() }
          self.lastState = "stopped"
          self.emit("stopped", message: nil)
          result(nil)
        } catch {
          if stopAttempt == self.attempt, !(error is CancellationError) {
            self.lastError = error.localizedDescription
            self.emit("error", message: self.lastError)
          }
          result(FlutterError(code: "stop_failed", message: error.localizedDescription, details: nil))
        }
      }
    case "status":
      Task { @MainActor in
        await self.refreshStatus()
        result(self.currentState())
      }
    case "coreVersion":
      result(coreVersion())
    case "readLog":
      let arguments = call.arguments as? [String: Any]
      let oomEvents = (try? sharedContainer().url).map { TunnelConfiguration.oomResetEvents(in: $0) } ?? []
      result(TunnelConfiguration.diagnosticLog(
        journal: readSharedFile("tunnel_lifecycle.jsonl"),
        stop: readSharedFile("last_stop.txt"), error: readSharedFile("last_error.txt"),
        maxLines: arguments?["maxLines"] as? Int ?? 200, oomEvents: oomEvents))
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
    try await preferences.perform { try await self.loadManagerPreferences(create: create) }
  }

  @MainActor
  private func loadManagerPreferences(create: Bool) async throws -> NETunnelProviderManager? {
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
    // Preserve the VPN when the device locks, including an older saved
    // configuration whose sleep policy may differ from the default.
    if proto.disconnectOnSleep {
      proto.disconnectOnSleep = false
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
    recoveryWarning = nil
    attempt += 1
    let currentAttempt = attempt
    starting = true
    defer { if currentAttempt == attempt { starting = false } }
    do {
      // Best effort: the payload also travels in the start options; the files are
      // what on-demand / system restarts and hot reloads use.
      let container = try? sharedContainer()
      var recoveryPayloadPersisted = false
      do {
        try writeSharedFile("config.json", config)
        try writeSharedFile("engine.json", engine)
        recoveryPayloadPersisted = true
      } catch { /* The inline payload can still start the current session. */ }
      try? writeSharedFile("last_error.txt", "")
      try? writeSharedFile("last_stop.txt", "")

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
          guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
          await enableRecoveryAfterConnection(attempt: currentAttempt, payloadPersisted: recoveryPayloadPersisted)
          guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
          lastState = "connected"
          emit("connected", message: nil)
          return
        }
      case .connecting:
        try await setRecoveryEnabled(false, attempt: currentAttempt)
        guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
        connection.stopVPNTunnel()
        try await waitForDisconnect(connection, attempt: currentAttempt)
      case .disconnecting:
        try await setRecoveryEnabled(false, attempt: currentAttempt)
        guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
        try await waitForDisconnect(connection, attempt: currentAttempt)
      default:
        break
      }
      guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
      lastState = "connecting"
      emit("connecting", message: nil)
      var options: [String: NSObject] = [
        "configContent": config as NSString,
        "engineContent": engine as NSString,
      ]
      if let group = container?.group {
        options["appGroup"] = group as NSString
      }
      do {
        // An older session may have enabled recovery. Do not let that policy
        // retry a replacement configuration until this start has succeeded.
        try await setRecoveryEnabled(false, attempt: currentAttempt)
        guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
        try connection.startVPNTunnel(options: options)
        try await waitForConnection(connection, attempt: currentAttempt)
      } catch {
        if currentAttempt == attempt {
          do {
            try await setRecoveryEnabled(false, attempt: currentAttempt)
          } catch let recoveryError {
            guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
            connection.stopVPNTunnel()
            throw bridgeError("VPN startup failed and automatic reconnect could not be disabled: \(recoveryError.localizedDescription)")
          }
          guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
          connection.stopVPNTunnel()
        }
        guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
        throw error
      }
      await enableRecoveryAfterConnection(attempt: currentAttempt, payloadPersisted: recoveryPayloadPersisted)
      guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
      lastState = "connected"
      emit("connected", message: nil)
    } catch {
      guard currentAttempt == attempt, !userStopped else { throw CancellationError() }
      throw error
    }
  }

  @MainActor
  private func enableRecoveryAfterConnection(attempt currentAttempt: Int, payloadPersisted: Bool) async {
    do {
      try await setRecoveryEnabled(payloadPersisted, attempt: currentAttempt)
      if !payloadPersisted { throw bridgeError("The configuration could not be saved in the shared container.") }
    } catch {
      guard currentAttempt == attempt, !userStopped else { return }
      recoveryWarning = "VPN is connected, but automatic reconnect could not be enabled: \(error.localizedDescription)"
    }
  }

  @MainActor
  private func setRecoveryEnabled(_ enabled: Bool, attempt requestedAttempt: Int) async throws {
    try await preferences.perform {
      // Preference saves are asynchronous. Serialize them so an older start
      // cannot finish its save after a newer explicit stop has disabled it.
      guard TunnelConfiguration.mayUpdateOnDemand(enabling: enabled, requestedAttempt: requestedAttempt,
          currentAttempt: self.attempt, userStopped: self.userStopped) else { throw CancellationError() }
      guard let manager = self.manager else { throw self.bridgeError("VPN configuration is not available") }
      if enabled {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = [rule]
      }
      manager.isOnDemandEnabled = enabled
      do {
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
      } catch {
        // Restore the actual stored state where possible; callers report the
        // failure rather than pretending that recovery was changed.
        try? await manager.loadFromPreferences()
        throw error
      }
      guard TunnelConfiguration.mayUpdateOnDemand(enabling: enabled, requestedAttempt: requestedAttempt,
          currentAttempt: self.attempt, userStopped: self.userStopped) else { throw CancellationError() }
    }
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
    let coreError = readSharedFile("last_error.txt")
    let stopReason = readSharedFile("last_stop.txt")
    guard #available(iOS 16.0, *) else {
      return TunnelConfiguration.disconnectMessage(tunnelError: coreError, systemError: stopReason)
    }
    return await withCheckedContinuation { continuation in
      var completed = false
      let finish: (String?) -> Void = { message in
        DispatchQueue.main.async {
          guard !completed else { return }
          completed = true
          continuation.resume(returning: TunnelConfiguration.disconnectMessage(tunnelError: coreError,
            systemError: TunnelConfiguration.disconnectMessage(tunnelError: message, systemError: stopReason)))
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
      connection.fetchLastDisconnectError { finish($0?.localizedDescription) }
    }
  }

  @MainActor
  private func reload(_ session: NETunnelProviderSession, config: String, engine: String) async throws {
    var payload: [String: String] = [
      "action": "reload", "configContent": config, "engineContent": engine,
    ]
    if let group = (try? sharedContainer())?.group {
      payload["appGroup"] = group
    }
    let message = try JSONSerialization.data(withJSONObject: payload)
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
  private func waitForDisconnect(_ connection: NEVPNConnection, attempt currentAttempt: Int) async throws {
    for _ in 0 ..< 50 {
      guard currentAttempt == attempt else { throw CancellationError() }
      if connection.status == .disconnected || connection.status == .invalid {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw bridgeError("iOS did not stop the previous VPN session. Try disabling Melsi in Settings > VPN.")
  }

  // MARK: - Status

  @MainActor
  private func refreshStatus() async {
    let currentAttempt = attempt
    if manager == nil {
      _ = try? await loadManager(create: false)
    } else if !starting {
      try? await preferences.perform {
        guard currentAttempt == self.attempt, !self.starting else { return }
        try await self.manager?.loadFromPreferences()
      }
    }
    guard currentAttempt == attempt else { return }
    onStatusChanged()
  }

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
    if state == "connected" { lastError = nil }
    if state == "error" {
      emit(state, message: lastError)
      return
    }
    let previous = lastState
    lastState = state
    let journal = readSharedFile("tunnel_lifecycle.jsonl")
    let unreportedStop = manager != nil && TunnelConfiguration.hasUnreportedTunnelStop(journal)
    guard state == "stopped", previous != "stopped" || unreportedStop,
          !userStopped, !TunnelConfiguration.isExpectedTunnelStop(journal) else {
      emit(state, message: nil)
      return
    }
    // Unexpected stop: surface the extension's error, if any.
    let fileError = TunnelConfiguration.disconnectMessage(
      tunnelError: readSharedFile("last_error.txt"), systemError: readSharedFile("last_stop.txt"))
    let stoppedAttempt = attempt
    let report: (String?) -> Void = { [weak self] message in
      guard let self, self.attempt == stoppedAttempt, !self.userStopped,
            Self.mapStatus(self.manager?.connection.status ?? .disconnected) == "stopped" else { return }
      self.lastError = message.flatMap { $0.isEmpty ? nil : $0 } ?? "The VPN extension stopped unexpectedly."
      if let summary = TunnelConfiguration.lifecycleSummary(self.readSharedFile("tunnel_lifecycle.jsonl")) {
        self.lastError = "\(self.lastError!) \(summary)"
      }
      self.lastState = "error"
      self.emit("error", message: self.lastError)
    }
    if let connection = manager?.connection {
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Reuse the bounded fetch, so a missing system callback cannot leave
        // an unexpected background stop without an error event forever.
        report(await self.disconnectMessage(connection))
      }
    } else {
      report(fileError)
    }
  }

  private func emit(_ state: String, message: String?) {
    guard let eventSink else { return }
    var event: [String: Any] = ["state": state]
    if let message = message ?? (state == "connected" ? recoveryWarning : nil), !message.isEmpty {
      event["message"] = message
    }
    eventSink(event)
  }

  // MARK: - Shared container

  private func sharedContainer() throws -> TunnelConfiguration.SharedContainer {
    if let cachedContainer { return cachedContainer }
    guard let resolved = TunnelConfiguration.resolveSharedContainer(hint: TunnelConfiguration.effectiveHint(nil)) else {
      throw bridgeError("No writable App Group container. Sign the app and PacketTunnel with a profile that contains a shared App Group. Melsi uses \(Self.preferredAppGroup) when that container is writable; otherwise it uses a group from the profile.")
    }
    TunnelConfiguration.rememberAppGroup(resolved.group)
    cachedContainer = resolved
    return resolved
  }

  private func writeSharedFile(_ name: String, _ content: String) throws {
    let directory = try sharedContainer().url
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func readSharedFile(_ name: String) -> String? {
    guard let url = try? sharedContainer().url.appendingPathComponent(name) else { return nil }
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
