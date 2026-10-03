import Foundation
import Darwin

enum TunnelConfiguration {
    static let commandSocketPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func commandBaseDirectory(sharedDirectory: URL, sandboxDirectory: URL) throws -> URL {
        for directory in [sharedDirectory, sandboxDirectory.appendingPathComponent("s", isDirectory: true), sandboxDirectory] {
            if directory.appendingPathComponent("command.sock").path.utf8.count < commandSocketPathCapacity {
                return directory
            }
        }
        throw NSError(domain: "app.melsi.PacketTunnel", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "The VPN command socket path exceeds the system limit"])
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
}
