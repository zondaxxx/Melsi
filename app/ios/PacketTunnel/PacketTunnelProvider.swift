import Foundation
import Libbox
import NetworkExtension
import os.log

/// Melsi packet tunnel.
///
/// Lifecycle (docs/CONTRACT.md §5):
///   LibboxSetup -> LibboxNewCommandServer -> start() -> startOrReloadService(config)
///   -> MelsicoreStartEngine(engine)
/// and on stop: MelsicoreStopEngine() -> closeService() -> close().
///
/// The app writes `config.json` / `engine.json` into the shared App Group
/// container before calling `startVPNTunnel(options:)`; the same payload may
/// also be passed in the start options (`configContent`, `engineContent`,
/// `appGroup`). Options win, the files are the fallback (on-demand / system
/// restarts start the tunnel without options).
///
/// `group.app.melsi` is preferred. A re-signed build whose profile uses
/// another group still shares that container with the app.
class PacketTunnelProvider: NEPacketTunnelProvider {
    static let log = OSLog(subsystem: "app.melsi.PacketTunnel", category: "tunnel")

    private static let containerLock = NSLock()
    private static var chosenContainer: TunnelConfiguration.SharedContainer?
    private static let fallbackSharedDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Melsi", isDirectory: true)

    private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = MelsiPlatformInterface(self)
    private var engineRunning = false

    // MARK: - Paths

    static var activeAppGroup: String? {
        containerLock.lock()
        defer { containerLock.unlock() }
        return chosenContainer?.group
    }

    static var sharedDirectory: URL {
        containerLock.lock()
        defer { containerLock.unlock() }
        if chosenContainer == nil {
            adoptLocked(hint: nil)
        }
        return chosenContainer?.url ?? fallbackSharedDirectory
    }

    /// `hint` is the group the app already selected (`appGroup` start option).
    /// An explicit hint can replace a container chosen earlier in this process.
    static func adoptSharedContainer(hint: String?) {
        containerLock.lock()
        defer { containerLock.unlock() }
        adoptLocked(hint: hint)
    }

    private static func adoptLocked(hint: String?) {
        let explicit = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitHint = (explicit?.isEmpty == false) ? explicit : nil
        if let current = chosenContainer, explicitHint == nil || explicitHint == current.group {
            return
        }
        let resolved = TunnelConfiguration.resolveSharedContainer(hint: TunnelConfiguration.effectiveHint(explicitHint))
        guard let resolved else { return }
        chosenContainer = resolved
        TunnelConfiguration.rememberAppGroup(resolved.group)
    }

    static var workingDirectory: URL {
        sharedDirectory.appendingPathComponent("Library/Caches/Working", isDirectory: true)
    }

    static var cacheDirectory: URL {
        sharedDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    // MARK: - Start / stop

    override func startTunnel(options: [String: NSObject]?) async throws {
        Self.adoptSharedContainer(hint: options?["appGroup"] as? String)
        let fileManager = FileManager.default
        let sandboxDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let commandDirectory = try TunnelConfiguration.commandBaseDirectory(
            sharedDirectory: Self.sharedDirectory,
            sandboxDirectory: sandboxDirectory,
            isUsable: { TunnelConfiguration.directoryIsWritable($0) })
        let basePath = commandDirectory.path
        let workingPath = Self.workingDirectory.path
        let tempPath = Self.cacheDirectory.path
        for directory in [Self.sharedDirectory, commandDirectory, Self.workingDirectory, Self.cacheDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw fail("create \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let group = Self.activeAppGroup {
            os_log("shared app group %{public}@", log: Self.log, type: .default, group)
        }
        clearLastError()

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = basePath
        setupOptions.workingPath = workingPath
        setupOptions.tempPath = tempPath
        setupOptions.logMaxLines = 3000
        setupOptions.debug = false
        setupOptions.crashReportSource = "NetworkExtension"
        setupOptions.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        setupOptions.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        // iOS Network Extensions are killed above ~50 MB: let libbox apply its
        // default NE memory limit + GC tuning (see libbox setup.go).
        setupOptions.oomKillerEnabled = true

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            throw fail("setup libbox: \(setupError.localizedDescription)")
        }

        var serverError: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        if let serverError {
            throw fail("create command server: \(serverError.localizedDescription)")
        }
        guard let commandServer else {
            throw fail("create command server: nil")
        }
        do {
            try commandServer.start()
        } catch {
            throw fail("start command server: \(error.localizedDescription)")
        }

        let payload = try loadPayload(options)
        try startService(payload)
        writeVersionFile()
        writeMessage("(packet-tunnel) started")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason.rawValue)")
        stopEngine()
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100_000_000)
            server.close()
            commandServer = nil
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        if let object = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: String],
           object["action"] == "reload" {
            do {
                Self.adoptSharedContainer(hint: object["appGroup"])
                let options = object.mapValues { $0 as NSObject }
                let payload = try loadPayload(options)
                reasserting = true
                defer { reasserting = false }
                try startService(payload)
                return nil
            } catch {
                return error.localizedDescription.data(using: .utf8)
            }
        }
        let message = String(data: messageData, encoding: .utf8) ?? ""
        switch message {
        case "reload":
            do {
                let payload = try loadPayload(nil)
                reasserting = true
                defer { reasserting = false }
                try startService(payload)
                return nil
            } catch {
                return error.localizedDescription.data(using: .utf8)
            }
        case "version":
            return versionJSON().data(using: .utf8)
        case "engineStatus":
            return MelsicoreEngineStatus().data(using: .utf8)
        default:
            return nil
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    // MARK: - Service

    struct Payload {
        var config: String
        var engine: String
    }

    private func loadPayload(_ options: [String: NSObject]?) throws -> Payload {
        var config = options?["configContent"] as? String
        var engine = options?["engineContent"] as? String
        if config == nil || config!.isEmpty {
            config = try? String(contentsOf: Self.sharedDirectory.appendingPathComponent("config.json"), encoding: .utf8)
        }
        if engine == nil || engine!.isEmpty {
            engine = try? String(contentsOf: Self.sharedDirectory.appendingPathComponent("engine.json"), encoding: .utf8)
        }
        guard let config, !config.isEmpty else {
            throw fail("missing sing-box configuration")
        }
        if options != nil {
            try config.write(to: Self.sharedDirectory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            try (engine ?? "").write(to: Self.sharedDirectory.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        }
        return Payload(config: try patchConfig(config), engine: engine ?? "")
    }

    /// The Dart side cannot know the App Group path of the extension, so force
    /// `experimental.cache_file.path` into the shared working directory.
    private func patchConfig(_ config: String) throws -> String {
        try TunnelConfiguration.patch(config, workingDirectory: Self.workingDirectory,
            ruleSetDirectory: Bundle.main.resourceURL?.appendingPathComponent("rulesets"))
    }

    private func startService(_ payload: Payload) throws {
        guard let commandServer else {
            throw fail("command server not started")
        }
        stopEngine()
        do {
            try commandServer.startOrReloadService(payload.config, options: LibboxOverrideOptions())
        } catch {
            throw fail("start service: \(error.localizedDescription)")
        }
        if !payload.engine.isEmpty {
            var engineError: NSError?
            MelsicoreStartEngine(payload.engine, &engineError)
            if let engineError {
                // The tunnel itself works without the engine (manual selection),
                // so report but do not tear the VPN down.
                writeMessage("(packet-tunnel) start engine: \(engineError.localizedDescription)")
                saveLastError("engine: \(engineError.localizedDescription)")
            } else {
                engineRunning = true
            }
        }
    }

    func stopEngine() {
        if engineRunning {
            MelsicoreStopEngine()
            engineRunning = false
        }
    }

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    /// Called by libbox (CommandServerHandler.ServiceReload) when a client asks
    /// for a reload.
    func reloadService() throws {
        let payload = try loadPayload(nil)
        reasserting = true
        defer { reasserting = false }
        try startService(payload)
    }

    // MARK: - Helpers

    func writeMessage(_ message: String) {
        os_log("%{public}@", log: Self.log, type: .default, message)
        commandServer?.writeMessage(4, message: message) // 4 = info (sing log.Level)
    }

    private func fail(_ message: String) -> NSError {
        let text = "(packet-tunnel) \(message)"
        os_log("%{public}@", log: Self.log, type: .error, text)
        saveLastError(message)
        return NSError(domain: "app.melsi.PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func saveLastError(_ message: String) {
        try? message.write(to: Self.sharedDirectory.appendingPathComponent("last_error.txt"), atomically: true, encoding: .utf8)
    }

    private func clearLastError() {
        try? FileManager.default.removeItem(at: Self.sharedDirectory.appendingPathComponent("last_error.txt"))
    }

    private func versionJSON() -> String {
        let object: [String: String] = [
            "sing_box": LibboxVersion(),
            "melsi": MelsicoreVersion(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func writeVersionFile() {
        try? versionJSON().write(to: Self.sharedDirectory.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
    }
}
