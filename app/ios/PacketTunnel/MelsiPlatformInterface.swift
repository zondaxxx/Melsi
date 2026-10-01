import Foundation
import Libbox
import Network
import NetworkExtension
import os.log

/// libbox PlatformInterface + CommandServerHandler for the iOS packet tunnel.
///
/// Swift method names mirror sing-box-for-apple (the reference client pinned by
/// sing-box v1.14.2, Library/Network/ExtensionPlatformInterface.swift): they are
/// the Clang-imported names of the gomobile-generated ObjC protocols
/// `LibboxPlatformInterface` / `LibboxCommandServerHandler`.
final class MelsiPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private unowned let tunnel: PacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?
    private var lastNetworkPath: String?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "app.melsi.PacketTunnel", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - TUN

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTun0(options, ret0_)
        }
    }

    private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options else {
            throw Self.error("nil tun options")
        }
        guard let ret0_ else {
            throw Self.error("nil return pointer")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            if options.getDNSMode()!.value != LibboxDNSModeDisabled {
                let dnsServerIterator = try options.getDNSServerAddress()
                var dnsServers: [String] = []
                while dnsServerIterator.hasNext() {
                    dnsServers.append(dnsServerIterator.next())
                }
                if !dnsServers.isEmpty {
                    let newDNSSettings = NEDNSSettings(servers: dnsServers)
                    // Send every DNS query into the tunnel (sing-box hijacks it).
                    newDNSSettings.matchDomains = [""]
                    newDNSSettings.matchDomainsNoSearch = true
                    settings.dnsSettings = newDNSSettings
                }
            }

            // IPv4
            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            while ipv4AddressIterator.hasNext() {
                let ipv4Prefix = ipv4AddressIterator.next()!
                ipv4Address.append(ipv4Prefix.address())
                ipv4Mask.append(ipv4Prefix.mask())
            }
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
            var ipv4Routes: [NEIPv4Route] = []
            var ipv4ExcludeRoutes: [NEIPv4Route] = []
            let inet4RouteAddressIterator = options.getInet4RouteAddress()!
            if inet4RouteAddressIterator.hasNext() {
                while inet4RouteAddressIterator.hasNext() {
                    let prefix = inet4RouteAddressIterator.next()!
                    ipv4Routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            } else {
                ipv4Routes.append(NEIPv4Route.default())
            }
            let inet4RouteExcludeAddressIterator = options.getInet4RouteExcludeAddress()!
            while inet4RouteExcludeAddressIterator.hasNext() {
                let prefix = inet4RouteExcludeAddressIterator.next()!
                ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
            settings.ipv4Settings = ipv4Settings

            // IPv6
            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            let ipv6AddressIterator = options.getInet6Address()!
            while ipv6AddressIterator.hasNext() {
                let ipv6Prefix = ipv6AddressIterator.next()!
                ipv6Address.append(ipv6Prefix.address())
                ipv6Prefixes.append(NSNumber(value: ipv6Prefix.prefix()))
            }
            do {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                var ipv6ExcludeRoutes: [NEIPv6Route] = []
                let inet6RouteAddressIterator = options.getInet6RouteAddress()!
                if inet6RouteAddressIterator.hasNext() {
                    while inet6RouteAddressIterator.hasNext() {
                        let prefix = inet6RouteAddressIterator.next()!
                        ipv6Routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                } else {
                    ipv6Routes.append(NEIPv6Route.default())
                }
                let inet6RouteExcludeAddressIterator = options.getInet6RouteExcludeAddress()!
                while inet6RouteExcludeAddressIterator.hasNext() {
                    let prefix = inet6RouteExcludeAddressIterator.next()!
                    ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
                ipv6Settings.includedRoutes = ipv6Routes
                ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
                settings.ipv6Settings = ipv6Settings
            }
        }

        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true
            var bypassDomains: [String] = []
            let bypassDomainIterator = options.getHTTPProxyBypassDomain()!
            while bypassDomainIterator.hasNext() {
                bypassDomains.append(bypassDomainIterator.next())
            }
            if !bypassDomains.isEmpty {
                proxySettings.exceptionList = bypassDomains
            }
            var matchDomains: [String] = []
            let matchDomainIterator = options.getHTTPProxyMatchDomain()!
            while matchDomainIterator.hasNext() {
                matchDomains.append(matchDomainIterator.next())
            }
            if !matchDomains.isEmpty {
                proxySettings.matchDomains = matchDomains
            }
            settings.proxySettings = proxySettings
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }
        // iOS 16+: packetFlow no longer exposes the socket; scan for the utun fd.
        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw Self.error("missing tun file descriptor")
        }
    }

    // MARK: - Interface control / process lookup

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func autoDetectControl(_: Int32) throws {}

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw Self.error("not implemented")
    }

    func useProcFS() -> Bool {
        false
    }

    func writeLog(_ message: String?) {
        guard let message else {
            return
        }
        tunnel.writeMessage(message)
    }

    // MARK: - Default interface monitor

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else {
            return
        }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            self.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                self.onUpdateDefaultInterface(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    private func onUpdateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        let networkPath = describeNetworkPath(path)
        listener.updateNetworkPath(networkPath)
        if networkPath == lastNetworkPath {
            return
        }
        lastNetworkPath = networkPath
        guard path.status != .unsatisfied, let defaultInterface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private func describeNetworkPath(_ path: Network.NWPath) -> String {
        var components: [String] = []
        switch path.status {
        case .satisfied:
            components.append("satisfied")
        case .unsatisfied:
            components.append("unsatisfied")
        case .requiresConnection:
            components.append("requiresConnection")
        @unknown default:
            components.append("unknown")
        }
        if !path.availableInterfaces.isEmpty {
            components.append("interfaces=" + path.availableInterfaces.map { "\($0.name)#\($0.index)" }.joined(separator: ","))
        }
        if path.supportsIPv4 {
            components.append("ipv4")
        }
        if path.supportsIPv6 {
            components.append("ipv6")
        }
        if path.supportsDNS {
            components.append("dns")
        }
        if path.isExpensive {
            components.append("expensive")
        }
        if path.isConstrained {
            components.append("constrained")
        }
        return components.joined(separator: " ")
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw Self.error("NWPathMonitor not started")
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let networkInterface = LibboxNetworkInterface()
            networkInterface.name = it.name
            networkInterface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                networkInterface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                networkInterface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                networkInterface.type = LibboxInterfaceTypeEthernet
            default:
                networkInterface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(networkInterface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    final class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    // MARK: - Environment

    func underNetworkExtension() -> Bool {
        true
    }

    func includeAllNetworks() -> Bool {
        false
    }

    func clearDNSCache() {
        guard let networkSettings else {
            return
        }
        runBlocking {
            self.tunnel.reasserting = true
            defer { self.tunnel.reasserting = false }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(nil) { _ in
                    continuation.resume()
                }
            }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(networkSettings) { _ in
                    continuation.resume()
                }
            }
        }
    }

    func readWIFIState() -> LibboxWIFIState? {
        // Needs the Access WiFi Information entitlement + location permission;
        // Melsi does not use SSID-based rules.
        nil
    }

    // MARK: - Notifications (not used)

    func send(_: LibboxNotification?) throws {}

    func cancelNotification(_: String?, typeID _: Int32) throws {}

    // MARK: - Neighbor / shell / bridge (unsupported on iOS)

    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func registerMyInterface(_: String?) {}

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    func usePlatformShell() -> Bool {
        false
    }

    func checkPlatformShell() throws {
        throw Self.error("SSH server is not supported")
    }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw Self.error("SSH server is not supported")
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw Self.error("SSH server is not supported")
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.error("not supported on this platform")
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.error("not supported on this platform")
        return ""
    }

    func tailscaleHostname() -> String {
        "melsi-ios"
    }

    func usePlatformBridge() -> Bool {
        false
    }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw Self.error("bridge is not supported on this platform")
    }

    // MARK: - CommandServerHandler

    func serviceStop() throws {
        tunnel.stopEngine()
        tunnel.stopService()
    }

    func serviceReload() throws {
        try tunnel.reloadService()
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let proxySettings = networkSettings?.proxySettings, proxySettings.httpServer != nil else {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings, let proxySettings = networkSettings.proxySettings, proxySettings.httpServer != nil else {
            return
        }
        if proxySettings.httpEnabled == isEnabled {
            return
        }
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxySettings
        try runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(networkSettings)
        }
    }

    func triggerNativeCrash() throws {}

    func writeDebugMessage(_ message: String?) {
        guard let message else {
            return
        }
        os_log("%{public}@", log: PacketTunnelProvider.log, type: .debug, message)
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw Self.error("SSH agent forwarding is not supported")
    }
}

// MARK: - runBlocking (from sing-box-for-apple)

func runBlocking<T>(_ block: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        let value = await block()
        box.result0 = value
        semaphore.signal()
    }
    semaphore.wait()
    return box.result0
}

func runBlocking<T>(_ tBlock: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        do {
            let value = try await tBlock()
            box.result = .success(value)
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result.get()
}

private final class ResultBox<T> {
    var result: Result<T, Error>!
    var result0: T!
}
