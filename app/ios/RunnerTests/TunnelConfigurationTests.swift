import Foundation
import XCTest
import Darwin

final class TunnelConfigurationTests: XCTestCase {
    func testOOMResetDiagnosticsIncludeOnlyTypedMetadata() {
        let input = #"{"t":"reset","at":"2026-10-08T10:00:01.123456789Z","reason":"threshold","memoryBytes":48234496,"memoryAfterBytes":31457280,"memoryLimit":52428800,"triggerBytes":47185920,"connections":8,"config":"secret-config","destination":"secret-host","runtime":{"token":"secret-token"}}"#
        let events = TunnelConfiguration.formatOOMResetEvents(Data(input.utf8))
        XCTAssertEqual(events, ["[memory guard] 2026-10-08T10:00:01Z: reset (threshold); memory 46.0 MiB; after 30.0 MiB; limit 50.0 MiB; trigger 45.0 MiB; connections 8"])
        XCTAssertFalse(events.joined().contains("secret"))
    }

    func testOOMResetDiagnosticsSkipMalformedLinesAndDistinguishReportOnly() {
        let input = [
            "partial-json",
            #"{"t":"snapshot","at":"2026-10-08T10:00:00Z","config":"secret"}"#,
            #"{"t":"reset","at":"secret-timestamp","reason":"threshold"}"#,
            #"{"t":"reset","at":"2026-10-08T10:00:00Z","reportOnly":"false"}"#,
            #"{"t":"reset","at":"2026-10-08T10:00:00Z","reason":"secret-reason","memoryBytes":"secret-size","memoryAfterBytes":true,"connections":-1}"#,
            #"{"t":"reset","at":"2026-10-08T10:00:01Z","reason":"rate","reportOnly":true,"memoryBytes":41943040}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(TunnelConfiguration.formatOOMResetEvents(Data(input.utf8)), [
            "[memory guard] 2026-10-08T10:00:00Z: reset (unknown)",
            "[memory guard] 2026-10-08T10:00:01Z: would reset (report only) (rate); memory 40.0 MiB",
        ])
    }

    func testOOMResetFileReadIsBoundedAndKeepsLastTwentyEvents() throws {
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shared) }
        XCTAssertTrue(TunnelConfiguration.oomResetEvents(in: shared).isEmpty)
        let directory = shared.appendingPathComponent("Library/Caches/Working/oom_draft")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let events = (0 ..< 25).map { index in
            String(format: "{\"t\":\"reset\",\"at\":\"2026-10-08T10:00:%02dZ\",\"reason\":\"threshold\"}", index)
        }.joined(separator: "\n")
        let oversizedPrefix = String(repeating: "x", count: TunnelConfiguration.oomEventReadLimit + 10)
        try (oversizedPrefix + "\n" + events + "\n{unfinished").write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try "secret-config".write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let result = TunnelConfiguration.oomResetEvents(in: shared)
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first, "[memory guard] 2026-10-08T10:00:05Z: reset (threshold)")
        XCTAssertEqual(result.last, "[memory guard] 2026-10-08T10:00:24Z: reset (threshold)")
        XCTAssertFalse(result.joined().contains("secret"))
    }

    func testOOMEventsRespectCombinedLogLimitAndKeepErrorVisible() {
        XCTAssertEqual(TunnelConfiguration.diagnosticLog(journal: "health", stop: "stop reason", error: "core error", maxLines: 3,
            oomEvents: ["[memory guard] reset"]), "[memory guard] reset\n[last stop] stop reason\n[last error] core error")
    }

    func testRecoveryPolicyRejectsOutdatedStartAndPreservesManualStop() {
        XCTAssertTrue(TunnelConfiguration.mayUpdateOnDemand(enabling: true, requestedAttempt: 1, currentAttempt: 1, userStopped: false))
        XCTAssertFalse(TunnelConfiguration.mayUpdateOnDemand(enabling: true, requestedAttempt: 1, currentAttempt: 2, userStopped: false))
        XCTAssertFalse(TunnelConfiguration.mayUpdateOnDemand(enabling: true, requestedAttempt: 1, currentAttempt: 1, userStopped: true))
        XCTAssertTrue(TunnelConfiguration.mayUpdateOnDemand(enabling: false, requestedAttempt: 2, currentAttempt: 2, userStopped: true))
        XCTAssertFalse(TunnelConfiguration.mayUpdateOnDemand(enabling: false, requestedAttempt: 2, currentAttempt: 3, userStopped: false))
    }

    func testPreferenceQueueSerializesSuspendedSavesAndRecoversAfterFailure() {
        let finished = expectation(description: "queued preference updates")
        let queue = TunnelPreferenceQueue()
        var events: [String] = []
        Task { @MainActor in
            try? await queue.perform {
                events.append("save started")
                try await Task.sleep(nanoseconds: 30_000_000)
                events.append("save failed")
                throw NSError(domain: "test", code: 1)
            }
        }
        Task { @MainActor in
            try? await queue.perform { events.append("stop saved") }
        }
        Task { @MainActor in
            try? await queue.perform { events.append("status loaded") }
            XCTAssertEqual(events, ["save started", "save failed", "stop saved", "status loaded"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }

    func testDiagnosticLogIsBoundedAndIncludesPersistedFailure() {
        XCTAssertEqual(TunnelConfiguration.diagnosticLog(journal: "start\nhealth\n", stop: "device sleep", error: "core failed", maxLines: 3),
            "health\n[last stop] device sleep\n[last error] core failed")
        XCTAssertEqual(TunnelConfiguration.diagnosticLog(journal: "start\nhealth", stop: nil, error: " \n", maxLines: 0), "health")
        let many = (0 ..< 450).map(String.init).joined(separator: "\n")
        XCTAssertEqual(TunnelConfiguration.diagnosticLog(journal: many, stop: nil, error: nil, maxLines: 999).split(separator: "\n").count, 400)
        XCTAssertEqual(TunnelConfiguration.diagnosticLog(journal: nil, stop: nil, error: nil, maxLines: 200), "")
    }

    func testLifecycleJournalPersistsBoundedHistoryAndStopReason() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 70 {
            try TunnelConfiguration.recordTunnelEvent("event-\(index)", in: directory, date: Date(timeIntervalSince1970: Double(index)))
        }
        try TunnelConfiguration.recordTunnelEvent("stopped", in: directory, stopReason: 15,
            memoryBytes: 32 * 1024 * 1024, date: Date(timeIntervalSince1970: 70))
        let text = try String(contentsOf: directory.appendingPathComponent("tunnel_lifecycle.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, TunnelConfiguration.lifecycleHistoryLimit)
        XCTAssertFalse(text.contains("\"event-0\""))
        XCTAssertTrue(text.contains("\"event-69\""))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("last_stop.txt"), encoding: .utf8),
            "VPN stopped: device sleep (15).")
        XCTAssertEqual(TunnelConfiguration.lifecycleSummary(text),
            "Last tunnel event: stopped at 1970-01-01T00:01:10Z; memory 32.0 MiB.")
    }

    func testLifecycleSummaryNeverInventsTerminationCause() throws {
        XCTAssertNil(TunnelConfiguration.lifecycleSummary(nil))
        XCTAssertNil(TunnelConfiguration.lifecycleSummary("not json"))
        XCTAssertEqual(TunnelConfiguration.lifecycleSummary("{\"event\":\"sleep\",\"at\":\"2026-10-08T00:00:00Z\"}\n"),
            "Last tunnel event: sleep at 2026-10-08T00:00:00Z.")
        XCTAssertEqual(TunnelConfiguration.stopReasonMessage(999), "VPN stopped: unknown system reason (999).")
        XCTAssertEqual(TunnelConfiguration.stopReasonMessage(11), "VPN stopped: another VPN started (11).")
    }

    func testResumeRecognizesMissingStopAndSystemFailureWithoutFlaggingUserStop() {
        XCTAssertTrue(TunnelConfiguration.hasUnreportedTunnelStop("{\"event\":\"health\"}"))
        XCTAssertTrue(TunnelConfiguration.hasUnreportedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":2}"))
        XCTAssertTrue(TunnelConfiguration.hasUnreportedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":15}"))
        XCTAssertFalse(TunnelConfiguration.hasUnreportedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":1}"))
        XCTAssertFalse(TunnelConfiguration.hasUnreportedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":11}"))
        XCTAssertFalse(TunnelConfiguration.hasUnreportedTunnelStop("{\"event\":\"start_failed\"}"))
        XCTAssertFalse(TunnelConfiguration.hasUnreportedTunnelStop(nil))
        XCTAssertTrue(TunnelConfiguration.isExpectedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":1}"))
        XCTAssertTrue(TunnelConfiguration.isExpectedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":11}"))
        XCTAssertFalse(TunnelConfiguration.isExpectedTunnelStop("{\"event\":\"stopped\",\"stop_reason\":2}"))
        XCTAssertFalse(TunnelConfiguration.isExpectedTunnelStop(nil))
    }

    func testCoreFailureIsNotHiddenByGenericIOSDisconnectError() {
        XCTAssertEqual(TunnelConfiguration.disconnectMessage(
            tunnelError: "start service: invalid REALITY public key",
            systemError: "The VPN connection failed"), "start service: invalid REALITY public key")
    }

    func testSystemDisconnectErrorIsUsedWithoutCoreFailure() {
        XCTAssertEqual(TunnelConfiguration.disconnectMessage(
            tunnelError: " \n", systemError: "The VPN extension was terminated"),
            "The VPN extension was terminated")
        XCTAssertNil(TunnelConfiguration.disconnectMessage(tunnelError: nil, systemError: nil))
    }

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

    func testPreferredGroupWinsWhenItsContainerIsWritable() {
        let preferred = TunnelConfiguration.preferredAppGroup
        let selected = TunnelConfiguration.selectSharedContainer(
            candidates: [preferred, "group.5c65ddfeba24ae58.1"],
            containerURL: { sharedContainer($0) },
            isWritable: { _ in true })
        XCTAssertEqual(selected?.group, preferred)
        XCTAssertTrue(TunnelConfiguration.isSharedAppGroupPath(sharedContainer(preferred)))
    }

    func testProfileGroupUsedWhenPreferredContainerIsNotShared() {
        let preferred = TunnelConfiguration.preferredAppGroup
        let profile = "group.5c65ddfeba24ae58.1"
        let selected = TunnelConfiguration.selectSharedContainer(
            candidates: TunnelConfiguration.candidateAppGroups(ownGroups: [profile, "group.5c65ddfeba24ae58.5"], counterpartGroups: ["group.5c65ddfeba24ae58.5", profile]),
            containerURL: { group in
                if group == preferred {
                    return URL(fileURLWithPath: "/private/var/mobile/Containers/Data/PluginKitPlugin/82204A2F-1B06-407D-9C82-8DE52414B66C")
                }
                return self.sharedContainer(group)
            },
            isWritable: { _ in true })
        XCTAssertEqual(selected?.group, profile)
        XCTAssertEqual(selected?.url.path, sharedContainer(profile).path)
    }

    func testHintIsTriedBeforeOtherProfileGroups() {
        let groups = ["group.5c65ddfeba24ae58.1", "group.5c65ddfeba24ae58.5"]
        let candidates = TunnelConfiguration.orderedCandidates(ownGroups: groups, counterpartGroups: groups.reversed(), hint: "group.5c65ddfeba24ae58.5")
        XCTAssertEqual(candidates.first, TunnelConfiguration.preferredAppGroup)
        XCTAssertEqual(candidates.dropFirst().first, "group.5c65ddfeba24ae58.5")
        let selected = TunnelConfiguration.selectSharedContainer(candidates: candidates, containerURL: { sharedContainer($0) }, isWritable: {
            $0.lastPathComponent == "group.5c65ddfeba24ae58.5"
        })
        XCTAssertEqual(selected?.group, "group.5c65ddfeba24ae58.5")
    }

    func testAppAndExtensionSelectTheSameResignedGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("melsi-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Melsi.app")
        let appex = app.appendingPathComponent("PlugIns/PacketTunnel.appex")
        let appGroups = ["group.5c65ddfeba24ae58.5", "group.5c65ddfeba24ae58.1"]
        let extensionGroups = ["group.5c65ddfeba24ae58.1", "group.5c65ddfeba24ae58.2", "group.5c65ddfeba24ae58.5"]
        try writeBundle(at: app, executable: "Melsi", groups: appGroups, packetTunnel: false)
        try writeBundle(at: appex, executable: "PacketTunnel", groups: extensionGroups, packetTunnel: true)

        let lookup: (String) -> URL? = { group in
            if group == TunnelConfiguration.preferredAppGroup { return nil }
            return self.sharedContainer(group)
        }
        let fromApp = TunnelConfiguration.resolveSharedContainer(bundleURL: app, plugInURLs: [appex], containerURL: lookup, isWritable: { _ in true })
        let fromExtension = TunnelConfiguration.resolveSharedContainer(bundleURL: appex, plugInURLs: [], containerURL: lookup, isWritable: { _ in true })
        XCTAssertEqual(fromApp?.group, "group.5c65ddfeba24ae58.1")
        XCTAssertEqual(fromApp, fromExtension)
    }

    func testExecutableSignatureSuppliesApplicationGroups() throws {
        let groups = ["group.5c65ddfeba24ae58.1", "group.5c65ddfeba24ae58.2"]
        let image = macho(signature: codeSignature(xml: entitlementsPlist(groups) + "\n", der: nil))
        XCTAssertEqual(TunnelConfiguration.applicationGroups(inExecutable: image), groups)
        let universal = fat(slice: image)
        XCTAssertEqual(TunnelConfiguration.applicationGroups(inExecutable: universal), groups)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("melsi-macho-\(UUID().uuidString)")
        try universal.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(TunnelConfiguration.applicationGroups(atExecutableURL: url), groups)
        XCTAssertEqual(TunnelConfiguration.applicationGroups(inExecutable: Data("not a binary".utf8)), [])
    }

    func testDEREntitlementsSupplyApplicationGroups() {
        let first = "group.5c65ddfeba24ae58.1"
        let second = "group.5c65ddfeba24ae58.2"
        let der = derSequence([
            derSequence([
                derString("com.apple.security.application-groups"),
                derSequence([derString(first), derString(second)]),
            ]),
        ])
        let image = macho(signature: codeSignature(xml: nil, der: der))
        XCTAssertEqual(TunnelConfiguration.applicationGroups(inExecutable: image), [first, second])
    }

    func testProvisioningProfileSuppliesApplicationGroups() throws {
        let groups = ["group.5c65ddfeba24ae58.1", "group.5c65ddfeba24ae58.2"]
        XCTAssertEqual(TunnelConfiguration.applicationGroups(inProvisioningProfile: profile(groups)), groups)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("melsi-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(at: root, executable: "PacketTunnel", groups: groups, packetTunnel: true, profileOnly: true)
        XCTAssertEqual(TunnelConfiguration.applicationGroups(inBundleAt: root), groups)
    }

    func testWritableSharedPathDoesNotCreateShortCommandDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/melsi-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("group")
        let sandbox = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let directory = try TunnelConfiguration.commandBaseDirectory(
            sharedDirectory: shared,
            sandboxDirectory: sandbox,
            isUsable: { TunnelConfiguration.directoryIsWritable($0) })
        XCTAssertEqual(directory.path, shared.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("s").path))
    }

    func testShortCommandDirectoryIsSkippedWhenUnusable() throws {
        let sandbox = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/PluginKitPlugin/6BF1D1ED-E67B-4767-B49E-7C0E850F27F1")
        let shared = sandbox.appendingPathComponent("Library/Application Support/Melsi")
        let directory = try TunnelConfiguration.commandBaseDirectory(
            sharedDirectory: shared,
            sandboxDirectory: sandbox,
            isUsable: { $0.lastPathComponent != "s" })
        XCTAssertEqual(directory, sandbox)
        XCTAssertNotEqual(directory.lastPathComponent, "s")
    }

    func testUnwritableCommandDirectoryFailsClearly() throws {
        let root = URL(fileURLWithPath: "/tmp/melsi-nowrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sandbox = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(sandbox.path, 0o555), 0)
        defer { chmod(sandbox.path, 0o755) }
        let shared = sandbox.appendingPathComponent("Library/Application Support/Melsi")
        XCTAssertLessThan(sandbox.appendingPathComponent("s").appendingPathComponent("command.sock").path.utf8.count,
                          TunnelConfiguration.commandSocketPathCapacity)
        XCTAssertThrowsError(try TunnelConfiguration.commandBaseDirectory(
            sharedDirectory: shared,
            sandboxDirectory: sandbox,
            isUsable: { TunnelConfiguration.directoryIsWritable($0) }
        )) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains("not writable"), message)
            XCTAssertTrue(message.contains("App Group"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("s").path))
    }

    private func sharedContainer(_ group: String) -> URL {
        URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/\(group)")
    }

    private func entitlementsPlist(_ groups: [String]) -> String {
        let items = groups.map { "<string>\($0)</string>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.application-groups</key><array>\(items)</array></dict></plist>
        """
    }

    private func profile(_ groups: [String]) -> Data {
        let items = groups.map { "<string>\($0)</string>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict><key>com.apple.security.application-groups</key><array>\(items)</array></dict></dict></plist>
        """
        return Data("MIME-boundary".utf8) + Data(xml.utf8) + Data([0x00])
    }

    private func codeSignature(xml: String?, der: Data?) -> Data {
        var entries: [(UInt32, Data)] = []
        if let xml {
            let payload = Data(xml.utf8)
            entries.append((5, be32(0xFADE7171) + be32(UInt32(8 + payload.count)) + payload))
        }
        if let der {
            entries.append((7, be32(0xFADE7172) + be32(UInt32(8 + der.count)) + der))
        }
        var indexes = Data()
        var body = Data()
        var cursor = 12 + 8 * entries.count
        for (type, blob) in entries {
            indexes.append(be32(type))
            indexes.append(be32(UInt32(cursor)))
            body.append(blob)
            cursor += blob.count
        }
        var signature = Data()
        signature.append(be32(0xFADE0CC0))
        signature.append(be32(UInt32(cursor)))
        signature.append(be32(UInt32(entries.count)))
        signature.append(indexes)
        signature.append(body)
        return signature
    }

    private func macho(signature: Data) -> Data {
        let words: [UInt32] = [0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0, 0x1D, 16, 48, UInt32(signature.count)]
        var image = Data()
        for value in words {
            image.append(le32(value))
        }
        image.append(signature)
        return image
    }

    private func fat(slice: Data) -> Data {
        let words: [UInt32] = [0xCAFEBABE, 1, 0x0100000C, 0, 28, UInt32(slice.count), 2]
        var image = Data()
        for value in words {
            image.append(be32(value))
        }
        image.append(slice)
        return image
    }

    private func derString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return Data([0x0C, UInt8(bytes.count)]) + bytes
    }

    private func derSequence(_ parts: [Data]) -> Data {
        let body = parts.reduce(into: Data()) { $0.append($1) }
        return Data([0x30, UInt8(body.count)]) + body
    }

    private func le32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }

    private func be32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private func writeBundle(at url: URL, executable: String, groups: [String], packetTunnel: Bool, profileOnly: Bool = false) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleExecutable": executable]
        if packetTunnel {
            info["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"]
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Info.plist"))
        let binary = url.appendingPathComponent(executable)
        if profileOnly {
            try Data("not-a-mach-o".utf8).write(to: binary)
            try profile(groups).write(to: url.appendingPathComponent("embedded.mobileprovision"))
        } else {
            try macho(signature: codeSignature(xml: entitlementsPlist(groups), der: nil)).write(to: binary)
        }
    }

    private func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func decode(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
