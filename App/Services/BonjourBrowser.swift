import Foundation
import Network
import SystemConfiguration
import os.log

private let bonjourLog = Logger(subsystem: "app.watari.mac", category: "Bonjour")

struct BonjourPeer: Identifiable, Equatable, Hashable {
    /// One row per advertised service name (IPv4/IPv6/multi-iface collapsed).
    var id: String { name.lowercased() }
    var name: String
    var serviceType: String
    var domain: String
    /// Best-effort display hint; address resolved only when connecting.
    var detail: String

    var endpoint: NWEndpoint {
        .service(name: name, type: serviceType, domain: domain.isEmpty ? "local." : domain, interface: nil)
    }
}

/// Optional Nearby discovery via Bonjour / DNS-SD. Off under managed defaults.
///
/// Does **not** open cleartext TCP to the peer for resolve — that races the TLS
/// listener and surfaces NWError -9816 (`errSSLBadCipherSuite`) on launch when
/// this Mac’s own service appears in the browse set.
final class BonjourBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private var peersByName: [String: BonjourPeer] = [:]
    private var onUpdate: (([BonjourPeer]) -> Void)?
    private let lock = NSLock()

    /// Bonjour service type for Watari.
    static let serviceType = "_watari._tcp"

    func start(onUpdate: @escaping ([BonjourPeer]) -> Void) {
        stop()
        self.onUpdate = onUpdate
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                bonjourLog.error("Browser failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        lock.lock()
        peersByName.removeAll()
        lock.unlock()
    }

    private func handle(results: Set<NWBrowser.Result>) {
        let localNames = Self.localServiceNames()
        var next: [String: BonjourPeer] = [:]

        for result in results {
            guard case let .service(name: name, type: type, domain: domain, interface: _) = result.endpoint else {
                continue
            }
            if localNames.contains(name.lowercased()) {
                continue
            }
            let key = name.lowercased()
            // Dedupe multi-interface / IPv4+IPv6 browse hits by service name.
            if next[key] != nil { continue }
            next[key] = BonjourPeer(
                name: name,
                serviceType: type,
                domain: domain,
                detail: "Bonjour · \(domain.isEmpty ? "local" : domain)"
            )
        }

        lock.lock()
        peersByName = next
        publishLocked()
        lock.unlock()
    }

    private func publishLocked() {
        let list = peersByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let callback = onUpdate
        DispatchQueue.main.async {
            callback?(list)
        }
    }

    /// Names this Mac advertises (Computer / Local Host / localized).
    static func localServiceNames() -> Set<String> {
        var names = Set<String>()
        if let localized = Host.current().localizedName {
            names.insert(localized.lowercased())
        }
        let processHost = ProcessInfo.processInfo.hostName
        names.insert(processHost.lowercased())
        if let short = processHost.split(separator: ".").first {
            names.insert(String(short).lowercased())
        }
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            names.insert(computer.lowercased())
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            names.insert(local.lowercased())
        }
        return names
    }
}
