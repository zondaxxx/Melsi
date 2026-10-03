import Foundation
import XCTest
import Darwin

final class TunnelConfigurationTests: XCTestCase {
    func testResignedInstallationUsesShortCommandSocketPath() throws {
        for prefix in ["/var", "/private/var"] {
            let sandbox = URL(fileURLWithPath: "\(prefix)/mobile/Containers/Data/PluginKitPlugin/6BF1D1ED-E67B-4767-B49E-7C0E850F27F1")
            let shared = sandbox.appendingPathComponent("Library/Application Support/Melsi")
            XCTAssertGreaterThanOrEqual(shared.appendingPathComponent("command.sock").path.utf8.count,
                                        TunnelConfiguration.commandSocketPathCapacity)
            let directory = try TunnelConfiguration.commandBaseDirectory(sharedDirectory: shared, sandboxDirectory: sandbox)
            XCTAssertEqual(directory, sandbox.appendingPathComponent("s", isDirectory: true))
            XCTAssertLessThan(directory.appendingPathComponent("command.sock").path.utf8.count,
                              TunnelConfiguration.commandSocketPathCapacity)
        }
    }

    func testShortAppGroupCommandPathIsPreserved() throws {
        let shared = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/6BF1D1ED-E67B-4767-B49E-7C0E850F27F1")
        let directory = try TunnelConfiguration.commandBaseDirectory(sharedDirectory: shared,
            sandboxDirectory: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(directory, shared)
    }

    func testCommandPathLimitCountsUTF8Bytes() throws {
        let shared = URL(fileURLWithPath: "/" + String(repeating: "я", count: 48))
        let sandbox = URL(fileURLWithPath: "/sandbox")
        XCTAssertLessThan(shared.appendingPathComponent("command.sock").path.count,
                          TunnelConfiguration.commandSocketPathCapacity)
        let directory = try TunnelConfiguration.commandBaseDirectory(sharedDirectory: shared, sandboxDirectory: sandbox)
        XCTAssertEqual(directory, sandbox.appendingPathComponent("s", isDirectory: true))
    }

    func testOversizedCommandPathsFailBeforeStartingCore() {
        let directory = URL(fileURLWithPath: "/" + String(repeating: "a", count: TunnelConfiguration.commandSocketPathCapacity))
        XCTAssertThrowsError(try TunnelConfiguration.commandBaseDirectory(sharedDirectory: directory, sandboxDirectory: directory))
    }

    func testCommandSocketCanBindAfterLongPathFallback() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let shared = sandbox.appendingPathComponent("Library/Application Support/Melsi")
        let directory = try TunnelConfiguration.commandBaseDirectory(sharedDirectory: shared, sandboxDirectory: sandbox)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(directory.appendingPathComponent("command.sock").path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, "bind failed with errno \(errno)")
    }

    func testBundledRulesAndCacheUseExtensionPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = try TunnelConfiguration.bundledSources.map { tag, source -> [String: Any] in
            try Data([1]).write(to: directory.appendingPathComponent("\(tag).srs"))
            return ["type": "remote", "tag": tag, "format": "binary", "url": source]
        }
        let config = try encode([
            "route": ["rule_set": rules],
            "experimental": ["cache_file": ["enabled": true, "path": "/runner/cache.db"]],
        ])
        let root = try decode(TunnelConfiguration.patch(config, workingDirectory: directory, ruleSetDirectory: directory))
        let patched = try XCTUnwrap((root["route"] as? [String: Any])?["rule_set"] as? [[String: Any]])
        XCTAssertEqual(patched.count, 5)
        for rule in patched {
            let tag = try XCTUnwrap(rule["tag"] as? String)
            XCTAssertEqual(rule["initial_path"] as? String, directory.appendingPathComponent("\(tag).srs").path)
            XCTAssertEqual(rule["type"] as? String, "remote")
            XCTAssertEqual(rule["url"] as? String, TunnelConfiguration.bundledSources[tag])
        }
        let cache = (root["experimental"] as? [String: Any])?["cache_file"] as? [String: Any]
        XCTAssertEqual(cache?["path"] as? String, directory.appendingPathComponent("cache.db").path)
        XCTAssertEqual(cache?["enabled"] as? Bool, true)
    }

    func testCustomSourceIsNotReplacedByBundledRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("geoip-ru.srs"))
        let original: [String: Any] = ["type": "remote", "tag": "geoip-ru", "format": "binary",
                                      "url": "https://example.com/custom.srs", "initial_path": "/custom.srs"]
        let config = try encode(["route": ["rule_set": [original]]])
        let root = try decode(TunnelConfiguration.patch(config, workingDirectory: directory, ruleSetDirectory: directory))
        let rules = (root["route"] as? [String: Any])?["rule_set"] as? [[String: Any]]
        XCTAssertEqual(rules?.first?["initial_path"] as? String, "/custom.srs")
    }

    func testMissingBundledFilesKeepRemoteDownload() throws {
        let rule: [String: Any] = ["type": "remote", "tag": "geoip-ru", "format": "binary",
                                  "url": TunnelConfiguration.bundledSources["geoip-ru"]!]
        let config = try encode(["route": ["rule_set": [rule]], "outbounds": [["type": "direct"]]])
        let root = try decode(TunnelConfiguration.patch(config,
            workingDirectory: FileManager.default.temporaryDirectory, ruleSetDirectory: nil))
        let rules = (root["route"] as? [String: Any])?["rule_set"] as? [[String: Any]]
        XCTAssertNil(rules?.first?["initial_path"])
        XCTAssertEqual((root["outbounds"] as? [[String: Any]])?.first?["type"] as? String, "direct")
    }

    func testInvalidConfigurationFailsBeforeStartingCore() {
        XCTAssertThrowsError(try TunnelConfiguration.patch("not json",
            workingDirectory: FileManager.default.temporaryDirectory, ruleSetDirectory: nil))
        XCTAssertThrowsError(try TunnelConfiguration.patch("[]",
            workingDirectory: FileManager.default.temporaryDirectory, ruleSetDirectory: nil))
    }

    private func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func decode(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
