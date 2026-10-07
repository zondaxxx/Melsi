import Foundation
import Darwin

enum TunnelConfiguration {
    /// Official and CI builds declare this group. Re-signed installs (GBox and
    /// similar) often replace it with the provisioning profile's groups; both
    /// processes still prefer this id when its container is actually writable.
    static let preferredAppGroup = "group.app.melsi"
    static let rememberedAppGroupKey = "melsi.sharedAppGroup"
    static let commandSocketPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    private static let lifecycleLock = NSLock()
    static let lifecycleHistoryLimit = 64

    struct SharedContainer: Equatable {
        var group: String
        var url: URL
    }

    /// The extension records the underlying core failure. iOS often reports
    /// only that its provider disconnected, so preserve the more useful cause.
    static func disconnectMessage(tunnelError: String?, systemError: String?) -> String? {
        for message in [tunnelError, systemError] {
            guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { continue }
            return message
        }
        return nil
    }

    static func stopReasonMessage(_ reason: Int) -> String {
        let descriptions = [
            0: "no reason reported", 1: "stopped by user", 2: "provider failed",
            3: "network unavailable", 4: "network changed", 5: "provider disabled",
            6: "authentication canceled", 7: "configuration failed", 8: "idle timeout",
            9: "configuration disabled", 10: "configuration removed", 11: "another VPN started",
            12: "user logged out", 13: "user switched", 14: "connection failed",
            15: "device sleep", 16: "app update", 17: "iOS network extension error",
        ]
        return "VPN stopped: \(descriptions[reason] ?? "unknown system reason") (\(reason))."
    }

    /// Persists only lifecycle metadata, never configuration or server keys.
    /// A missing stop callback is evidence of an unreported termination, not
    /// proof of any particular cause such as a memory-pressure kill.
    static func recordTunnelEvent(_ event: String, in directory: URL, stopReason: Int? = nil, memoryBytes: UInt64? = nil, date: Date = Date()) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        var entry: [String: Any] = ["event": event, "at": ISO8601DateFormatter().string(from: date)]
        if let stopReason { entry["stop_reason"] = stopReason }
        if let memoryBytes { entry["physical_footprint_bytes"] = memoryBytes }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
        let url = directory.appendingPathComponent("tunnel_lifecycle.jsonl")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n").suffix(lifecycleHistoryLimit - 1).map(String.init)
        lines.append(line)
        try writeDiagnostic(lines.joined(separator: "\n") + "\n", to: url)
        if let stopReason {
            try writeDiagnostic(stopReasonMessage(stopReason), to: directory.appendingPathComponent("last_stop.txt"))
        }
    }

    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func lifecycleSummary(_ journal: String?) -> String? {
        guard let line = journal?.split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = object["event"] as? String,
              let date = object["at"] as? String else { return nil }
        var result = "Last tunnel event: \(event) at \(date)"
        if let bytes = object["physical_footprint_bytes"] as? NSNumber {
            result += String(format: "; memory %.1f MiB", bytes.doubleValue / 1_048_576)
        }
        return result + "."
    }

    static func hasUnreportedTunnelStop(_ journal: String?) -> Bool {
        guard let line = journal?.split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = object["event"] as? String else { return false }
        if event == "stopped", let reason = object["stop_reason"] as? Int {
            return ![1, 5, 9, 10, 11, 12, 13, 16].contains(reason)
        }
        return ["starting", "started", "sleep", "wake", "health"].contains(event)
    }

    static func isExpectedTunnelStop(_ journal: String?) -> Bool {
        guard let line = journal?.split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["event"] as? String == "stopped",
              let reason = object["stop_reason"] as? Int else { return false }
        return [1, 5, 9, 10, 11, 12, 13, 16].contains(reason)
    }

    static func mayUpdateOnDemand(enabling: Bool, requestedAttempt: Int, currentAttempt: Int, userStopped: Bool) -> Bool {
        requestedAttempt == currentAttempt && (!enabling || !userStopped)
    }

    static func diagnosticLog(journal: String?, stop: String?, error: String?, maxLines: Int) -> String {
        var lines = (journal ?? "").split(separator: "\n").map(String.init)
        for (label, text) in [("[last stop]", stop), ("[last error]", error)] {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            lines.append(contentsOf: text.split(separator: "\n").map { "\(label) \($0)" })
        }
        return lines.suffix(min(max(maxLines, 1), 400)).joined(separator: "\n")
    }

    private static func writeDiagnostic(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        #if os(iOS)
        // Keep diagnostics writable/readable after the first unlock, including
        // when the system stops a tunnel while the screen is locked.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    /// Directory that will hold `command.sock`.
    ///
    /// `group.app.melsi` (and any other real App Group container) is short
    /// enough. Without one, the extension sandbox path is not: libbox's socket
    /// name then needs a one-character directory at the sandbox root. That
    /// directory is returned only when `isUsable` accepts it, because a
    /// Network Extension cannot always create folders in its home directory.
    static func commandBaseDirectory(sharedDirectory: URL, sandboxDirectory: URL, isUsable: ((URL) -> Bool)? = nil) throws -> URL {
        let candidates = [
            sharedDirectory,
            sandboxDirectory.appendingPathComponent("s", isDirectory: true),
            sandboxDirectory,
        ]
        var rejectedUnusable = false
        for directory in candidates {
            guard directory.appendingPathComponent("command.sock").path.utf8.count < commandSocketPathCapacity else { continue }
            if let isUsable {
                guard isUsable(directory) else {
                    rejectedUnusable = true
                    continue
                }
            }
            return directory
        }
        if rejectedUnusable {
            throw NSError(domain: "app.melsi.PacketTunnel", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The VPN command directory is not writable. Sign the app and the PacketTunnel extension with a shared App Group.",
            ])
        }
        throw NSError(domain: "app.melsi.PacketTunnel", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "The VPN command socket path exceeds the system limit",
        ])
    }

    static func directoryIsWritable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let existed = fileManager.fileExists(atPath: url.path)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".melsi-writable-\(UUID().uuidString)")
            try Data([0x6D]).write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
            return true
        } catch {
            if !existed {
                try? fileManager.removeItem(at: url)
            }
            return false
        }
    }

    // MARK: - App Group selection

    /// Same order on both sides of the tunnel: the preferred group first, then
    /// the intersection of the two bundles' groups (or the only list we could
    /// read), sorted so profile order cannot make the app and extension diverge.
    static func candidateAppGroups(ownGroups: [String], counterpartGroups: [String]) -> [String] {
        orderedCandidates(ownGroups: ownGroups, counterpartGroups: counterpartGroups, hint: nil)
    }

    static func orderedCandidates(ownGroups: [String], counterpartGroups: [String], hint: String?) -> [String] {
        let own = dedupe(ownGroups)
        let other = dedupe(counterpartGroups)
        let shared: [String]
        if own.isEmpty {
            shared = other
        } else if other.isEmpty {
            shared = own
        } else {
            let otherSet = Set(other)
            let intersection = own.filter { otherSet.contains($0) }
            shared = intersection.isEmpty ? own : intersection
        }
        var result = [preferredAppGroup]
        result.append(contentsOf: shared.filter { $0 != preferredAppGroup }.sorted())
        result = dedupe(result)
        guard let hint = normalizeGroup(hint), hint != preferredAppGroup else { return result }
        result.removeAll { $0 == hint }
        let index = result.first == preferredAppGroup && !result.isEmpty ? 1 : 0
        result.insert(hint, at: index)
        return result
    }

    static func isSharedAppGroupPath(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/Shared/AppGroup/") || path.contains("/Group Containers/")
    }

    static func selectSharedContainer(candidates: [String], containerURL: (String) -> URL?, isWritable: (URL) -> Bool) -> SharedContainer? {
        var seen = Set<String>()
        for group in candidates {
            guard let group = normalizeGroup(group), seen.insert(group).inserted else { continue }
            guard let url = containerURL(group), isSharedAppGroupPath(url), isWritable(url) else { continue }
            return SharedContainer(group: group, url: url)
        }
        return nil
    }

    static func rememberedAppGroup() -> String? {
        normalizeGroup(UserDefaults.standard.string(forKey: rememberedAppGroupKey))
    }

    static func rememberAppGroup(_ group: String) {
        guard let group = normalizeGroup(group) else { return }
        UserDefaults.standard.set(group, forKey: rememberedAppGroupKey)
    }

    static func effectiveHint(_ explicit: String?) -> String? {
        normalizeGroup(explicit) ?? rememberedAppGroup()
    }

    /// Container shared by Runner and PacketTunnel.
    ///
    /// Pass `bundleURL` / `plugInURLs` in tests. Production reads the calling
    /// bundle, the other side of the app/extension pair, and `containerURL`.
    static func resolveSharedContainer(
        bundleURL: URL? = nil,
        plugInURLs: [URL]? = nil,
        hint: String? = nil,
        containerURL: ((String) -> URL?)? = nil,
        isWritable: ((URL) -> Bool)? = nil,
        fileManager: FileManager = .default
    ) -> SharedContainer? {
        let bundle = bundleURL ?? Bundle.main.bundleURL
        let plugins = plugInURLs ?? plugIns(in: bundle, fileManager: fileManager)
        let own = applicationGroups(inBundleAt: bundle, fileManager: fileManager)
        let counterpart = counterpartBundleURL(bundleURL: bundle, plugInURLs: plugins).map {
            applicationGroups(inBundleAt: $0, fileManager: fileManager)
        } ?? []
        let candidates = orderedCandidates(ownGroups: own, counterpartGroups: counterpart, hint: hint)
        let lookup = containerURL ?? { fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        let writable = isWritable ?? { directoryIsWritable($0, fileManager: fileManager) }
        return selectSharedContainer(candidates: candidates, containerURL: lookup, isWritable: writable)
    }

    static func plugIns(in bundle: URL, fileManager: FileManager = .default) -> [URL] {
        let directory = bundle.appendingPathComponent("PlugIns", isDirectory: true)
        return (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    static func counterpartBundleURL(bundleURL: URL, plugInURLs: [URL]) -> URL? {
        if bundleURL.pathExtension == "appex" {
            let parent = bundleURL.deletingLastPathComponent()
            guard parent.lastPathComponent == "PlugIns" else { return nil }
            return parent.deletingLastPathComponent()
        }
        if let tunnel = plugInURLs.first(where: isPacketTunnelBundle) {
            return tunnel
        }
        return plugInURLs.first { $0.pathExtension == "appex" }
    }

    static func applicationGroups(inBundleAt bundleURL: URL, fileManager: FileManager = .default) -> [String] {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
        let named = (info?["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let executableName = named.isEmpty ? bundleURL.deletingPathExtension().lastPathComponent : named
        var groups: [String] = []
        let executableURL = bundleURL.appendingPathComponent(executableName)
        if fileManager.fileExists(atPath: executableURL.path) {
            groups.append(contentsOf: applicationGroups(atExecutableURL: executableURL))
        }
        let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        if let profile = try? Data(contentsOf: profileURL) {
            groups.append(contentsOf: applicationGroups(inProvisioningProfile: profile))
        }
        return dedupe(groups)
    }

    // MARK: - Entitlements

    static func applicationGroups(inExecutable data: Data) -> [String] {
        for slice in machOSlices(data) {
            let groups = applicationGroups(inMachO: slice)
            if !groups.isEmpty { return groups }
        }
        return []
    }

    static func applicationGroups(atExecutableURL url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let fileSize = handle.seekToEndOfFile()
        guard fileSize >= 8 else { return [] }
        handle.seek(toFileOffset: 0)
        let magicData = handle.readData(ofLength: 4)
        guard magicData.count == 4 else { return [] }
        // Fat magic is big-endian on disk (CA FE BA BE). A little-endian read of
        // those bytes is 0xBEBAFECA, not 0xCAFEBABE.
        let magic = readU32(magicData, 0)
        if magic == 0xBEBAFECA || magic == 0xCAFEBABE {
            return applicationGroups(inFatFile: handle, fileSize: fileSize, bigEndian: magic == 0xBEBAFECA)
        }
        return applicationGroups(inMachOFile: handle, sliceOffset: 0, sliceSize: fileSize)
    }

    static func applicationGroups(inProvisioningProfile data: Data) -> [String] {
        guard let plist = plistSlice(data),
              let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let entitlements = object["Entitlements"]
        else { return [] }
        return applicationGroups(inEntitlementsObject: entitlements)
    }

    static let bundledSources = [
        "geoip-ru": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "geosite-category-ads-all": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
        "geosite-category-ru": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
        "geosite-ru-blocked": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs",
        "geoip-ru-blocked": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked.srs",
    ]

    static func patch(_ config: String, workingDirectory: URL, ruleSetDirectory: URL?) throws -> String {
        guard let data = config.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "app.melsi.PacketTunnel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid VPN configuration"])
        }
        if var experimental = root["experimental"] as? [String: Any],
           var cache = experimental["cache_file"] as? [String: Any] {
            cache["path"] = workingDirectory.appendingPathComponent("cache.db").path
            experimental["cache_file"] = cache
            root["experimental"] = experimental
        }
        if let directory = ruleSetDirectory,
           var route = root["route"] as? [String: Any],
           var ruleSets = route["rule_set"] as? [[String: Any]] {
            for index in ruleSets.indices {
                guard ruleSets[index]["type"] as? String == "remote",
                      ruleSets[index]["format"] as? String == "binary",
                      let tag = ruleSets[index]["tag"] as? String,
                      let source = bundledSources[tag],
                      ruleSets[index]["url"] as? String == source else { continue }
                let file = directory.appendingPathComponent("\(tag).srs")
                if FileManager.default.fileExists(atPath: file.path) {
                    ruleSets[index]["initial_path"] = file.path
                }
            }
            route["rule_set"] = ruleSets
            root["route"] = route
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    // MARK: - Parsing

    private static func applicationGroups(inMachO slice: Data) -> [String] {
        guard slice.count >= 32 else { return [] }
        let magic = readU32(slice, 0)
        let bigEndian = magic == 0xCFFAEDFE
        guard magic == 0xFEEDFACF || bigEndian else { return [] }
        let ncmds = Int(readU32(slice, 16, bigEndian: bigEndian))
        let sizeofcmds = Int(readU32(slice, 20, bigEndian: bigEndian))
        guard ncmds > 0, ncmds < 10_000, sizeofcmds >= 8, slice.count >= 32, sizeofcmds <= slice.count - 32 else { return [] }
        var cursor = 32
        let commandsEnd = 32 + sizeofcmds
        for _ in 0 ..< ncmds {
            guard cursor + 8 <= commandsEnd else { break }
            let cmd = readU32(slice, cursor, bigEndian: bigEndian)
            let cmdsize = Int(readU32(slice, cursor + 4, bigEndian: bigEndian))
            guard cmdsize >= 8, cursor + cmdsize <= slice.count else { break }
            if cmd == 0x1D, cursor + 16 <= slice.count {
                let dataoff = Int(readU32(slice, cursor + 8, bigEndian: bigEndian))
                let datasize = Int(readU32(slice, cursor + 12, bigEndian: bigEndian))
                guard dataoff >= 0, datasize > 0, dataoff <= slice.count, datasize <= slice.count - dataoff else { return [] }
                return applicationGroups(inCodeSignature: slice.subdata(in: dataoff ..< (dataoff + datasize)))
            }
            cursor += cmdsize
        }
        return []
    }

    private static func machOSlices(_ data: Data) -> [Data] {
        guard data.count >= 8 else { return [] }
        let magic = readU32(data, 0)
        if magic == 0xFEEDFACF || magic == 0xCFFAEDFE { return [data] }
        // See applicationGroups(atExecutableURL:) for the fat-magic byte order.
        let bigEndian = magic == 0xBEBAFECA
        guard bigEndian || magic == 0xCAFEBABE else { return [] }
        let count = Int(readU32(data, 4, bigEndian: bigEndian))
        guard count > 0, count < 16 else { return [] }
        var slices: [Data] = []
        for index in 0 ..< count {
            let arch = 8 + index * 20
            guard arch + 20 <= data.count else { break }
            let offset = Int(readU32(data, arch + 8, bigEndian: bigEndian))
            let size = Int(readU32(data, arch + 12, bigEndian: bigEndian))
            guard offset >= 0, size > 0, offset <= data.count, size <= data.count - offset else { continue }
            slices.append(data.subdata(in: offset ..< (offset + size)))
        }
        return slices
    }

    private static func applicationGroups(inFatFile handle: FileHandle, fileSize: UInt64, bigEndian: Bool) -> [String] {
        handle.seek(toFileOffset: 4)
        let countData = handle.readData(ofLength: 4)
        guard countData.count == 4 else { return [] }
        let count = Int(readU32(countData, 0, bigEndian: bigEndian))
        guard count > 0, count < 16 else { return [] }
        for index in 0 ..< count {
            let arch = UInt64(8 + index * 20)
            guard arch + 20 <= fileSize else { break }
            handle.seek(toFileOffset: arch)
            let header = handle.readData(ofLength: 20)
            guard header.count == 20 else { continue }
            let offset = UInt64(readU32(header, 8, bigEndian: bigEndian))
            let size = UInt64(readU32(header, 12, bigEndian: bigEndian))
            guard size > 0, offset + size <= fileSize else { continue }
            let groups = applicationGroups(inMachOFile: handle, sliceOffset: offset, sliceSize: size)
            if !groups.isEmpty { return groups }
        }
        return []
    }

    private static func applicationGroups(inMachOFile handle: FileHandle, sliceOffset: UInt64, sliceSize: UInt64) -> [String] {
        guard sliceSize >= 32, sliceOffset + sliceSize >= sliceOffset else { return [] }
        handle.seek(toFileOffset: sliceOffset)
        let header = handle.readData(ofLength: 32)
        guard header.count == 32 else { return [] }
        let magic = readU32(header, 0)
        let bigEndian = magic == 0xCFFAEDFE
        guard magic == 0xFEEDFACF || bigEndian else { return [] }
        let ncmds = Int(readU32(header, 16, bigEndian: bigEndian))
        let sizeofcmds = Int(readU32(header, 20, bigEndian: bigEndian))
        guard ncmds > 0, ncmds < 10_000, sizeofcmds >= 8, sizeofcmds < 1_000_000 else { return [] }
        guard sliceOffset + 32 + UInt64(sizeofcmds) <= sliceOffset + sliceSize else { return [] }
        handle.seek(toFileOffset: sliceOffset + 32)
        let commands = handle.readData(ofLength: sizeofcmds)
        guard commands.count == sizeofcmds else { return [] }
        var cursor = 0
        for _ in 0 ..< ncmds {
            guard cursor + 8 <= commands.count else { break }
            let cmd = readU32(commands, cursor, bigEndian: bigEndian)
            let cmdsize = Int(readU32(commands, cursor + 4, bigEndian: bigEndian))
            guard cmdsize >= 8 else { break }
            if cmd == 0x1D, cursor + 16 <= commands.count {
                let dataoff = UInt64(readU32(commands, cursor + 8, bigEndian: bigEndian))
                let datasize = Int(readU32(commands, cursor + 12, bigEndian: bigEndian))
                guard datasize > 0, datasize < 8_000_000, dataoff + UInt64(datasize) <= sliceSize else { return [] }
                handle.seek(toFileOffset: sliceOffset + dataoff)
                let signature = handle.readData(ofLength: datasize)
                guard signature.count == datasize else { return [] }
                return applicationGroups(inCodeSignature: signature)
            }
            guard cursor + cmdsize <= commands.count else { break }
            cursor += cmdsize
        }
        return []
    }

    private static func applicationGroups(inCodeSignature data: Data) -> [String] {
        guard data.count >= 12, readU32(data, 0, bigEndian: true) == 0xFADE0CC0 else { return [] }
        let count = Int(readU32(data, 8, bigEndian: true))
        guard count >= 0, count < 64, data.count >= 12, count <= (data.count - 12) / 8 else { return [] }
        var xml: Data?
        var der: Data?
        for index in 0 ..< count {
            let entry = 12 + index * 8
            let type = readU32(data, entry, bigEndian: true)
            let offset = Int(readU32(data, entry + 4, bigEndian: true))
            guard offset >= 0, offset + 8 <= data.count else { continue }
            let magic = readU32(data, offset, bigEndian: true)
            let length = Int(readU32(data, offset + 4, bigEndian: true))
            guard length >= 8, offset <= data.count, length <= data.count - offset else { continue }
            let body = data.subdata(in: (offset + 8) ..< (offset + length))
            if type == 5 || magic == 0xFADE7171 { xml = body }
            if type == 7 || magic == 0xFADE7172 { der = body }
        }
        if let xml {
            let groups = applicationGroups(inEntitlementsPlist: xml)
            if !groups.isEmpty { return groups }
        }
        if let der { return applicationGroups(inDER: der) }
        return []
    }

    private static func applicationGroups(inEntitlementsPlist data: Data) -> [String] {
        guard let plist = plistSlice(data),
              let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
        else { return [] }
        return applicationGroups(inEntitlementsObject: object)
    }

    private static func applicationGroups(inEntitlementsObject object: Any) -> [String] {
        guard let dict = object as? [String: Any] else { return [] }
        guard let value = dict["com.apple.security.application-groups"] else { return [] }
        if let group = value as? String { return dedupe([group]) }
        if let groups = value as? [String] { return dedupe(groups) }
        if let groups = value as? [Any] { return dedupe(groups.compactMap { $0 as? String }) }
        return []
    }

    private static func applicationGroups(inDER data: Data) -> [String] {
        guard let root = DERNode.parse(data) else { return [] }
        return applicationGroups(inDERNode: root)
    }

    private static func applicationGroups(inDERNode node: DERNode) -> [String] {
        let children = node.children
        for (index, child) in children.enumerated() where child.string == "com.apple.security.application-groups" && index + 1 < children.count {
            let groups = dedupe(children[index + 1].strings.filter { $0 != "com.apple.security.application-groups" })
            if !groups.isEmpty { return groups }
        }
        for child in children {
            let groups = applicationGroups(inDERNode: child)
            if !groups.isEmpty { return groups }
        }
        return []
    }

    private static func plistSlice(_ data: Data) -> Data? {
        if let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8)),
           start.lowerBound < end.upperBound {
            return data.subdata(in: start.lowerBound ..< end.upperBound)
        }
        if let start = data.range(of: Data("bplist".utf8)), start.lowerBound < data.count {
            return data.subdata(in: start.lowerBound ..< data.count)
        }
        return data.isEmpty ? nil : data
    }

    private static func isPacketTunnelBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "appex" else { return false }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
        let point = (info?["NSExtension"] as? NSDictionary)?["NSExtensionPointIdentifier"] as? String
        return point == "com.apple.networkextension.packet-tunnel"
    }

    private static func normalizeGroup(_ group: String?) -> String? {
        guard let group else { return nil }
        let value = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/"), !value.contains(".."), value.count < 256 else { return nil }
        return value
    }

    private static func dedupe(_ groups: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in groups {
            guard let value = normalizeGroup(group), seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func readU32(_ data: Data, _ offset: Int, bigEndian: Bool = false) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

/// NE preference reads and writes must share the same queue: a concurrent
/// load can otherwise replace an in-memory policy while it is being saved.
final class TunnelPreferenceQueue {
    private var pending: Task<Void, Error>?

    @MainActor
    func perform<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = pending
        let next = Task { @MainActor in
            _ = try? await previous?.value
            return try await operation()
        }
        pending = Task { @MainActor in _ = try await next.value }
        return try await next.value
    }
}

private struct DERNode {
    var tag: UInt8
    var contents: Data
    var children: [DERNode]

    var string: String? {
        guard tag == 0x0C || tag == 0x13 || tag == 0x16 else { return nil }
        return String(data: contents, encoding: .utf8)
    }

    var strings: [String] {
        if let string { return [string] }
        return children.flatMap { $0.strings }
    }

    static func parse(_ data: Data) -> DERNode? {
        var index = 0
        guard let node = parseNode(data, index: &index), index <= data.count else { return nil }
        return node
    }

    private static func parseNode(_ data: Data, index: inout Int) -> DERNode? {
        guard index < data.count else { return nil }
        let tag = data[index]
        index += 1
        guard let length = readLength(data, index: &index), length >= 0, index <= data.count, length <= data.count - index else { return nil }
        let contents = data.subdata(in: index ..< (index + length))
        index += length
        var children: [DERNode] = []
        if tag & 0x20 != 0 {
            var childIndex = 0
            while childIndex < contents.count {
                let start = childIndex
                guard let child = parseNode(contents, index: &childIndex), childIndex > start else { break }
                children.append(child)
            }
        }
        return DERNode(tag: tag, contents: contents, children: children)
    }

    private static func readLength(_ data: Data, index: inout Int) -> Int? {
        guard index < data.count else { return nil }
        let first = data[index]
        index += 1
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, index + count <= data.count else { return nil }
        var length = 0
        for _ in 0 ..< count {
            length = (length << 8) | Int(data[index])
            index += 1
        }
        return length
    }
}
