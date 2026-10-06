import Foundation
import Network
import os.log

private let bonjourLog = Logger(subsystem: "app.watari.mac", category: "Bonjour")

struct BonjourPeer: Identifiable, Equatable, Hashable {
    var id: String { "\(name)|\(host)|\(port)" }
    var name: String
    var host: String
    var port: Int
}

/// Optional Nearby discovery via Bonjour / DNS-SD. Off under managed defaults.
final class BonjourBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private var resolvers: [ObjectIdentifier: NWConnection] = [:]
    private var peersByID: [String: BonjourPeer] = [:]
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
        let active = resolvers
        resolvers.removeAll()
        peersByID.removeAll()
        lock.unlock()
        for (_, connection) in active {
            connection.cancel()
        }
    }

    private func handle(results: Set<NWBrowser.Result>) {
        let services = results.filter {
            if case .service = $0.endpoint { return true }
            return false
        }
        lock.lock()
        // Drop resolvers for vanished services.
        let currentNames: Set<String> = Set(services.compactMap {
            if case let .service(name: name, type: _, domain: _, interface: _) = $0.endpoint {
                return name
            }
            return nil
        })
        peersByID = peersByID.filter { currentNames.contains($0.value.name) }
        publishLocked()
        lock.unlock()

        for result in services {
            resolve(result)
        }
        if services.isEmpty {
            lock.lock()
            peersByID.removeAll()
            publishLocked()
            lock.unlock()
        }
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        lock.lock()
        resolvers[ObjectIdentifier(connection)] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint {
                    let resolved = Self.hostPort(from: endpoint)
                    if let resolved {
                        let peer = BonjourPeer(name: name, host: resolved.host, port: resolved.port)
                        self.lock.lock()
                        self.peersByID[peer.id] = peer
                        self.publishLocked()
                        self.lock.unlock()
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                self.lock.lock()
                self.resolvers[ObjectIdentifier(connection)] = nil
                self.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func publishLocked() {
        let list = peersByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let callback = onUpdate
        DispatchQueue.main.async {
            callback?(list)
        }
    }

    private static func hostPort(from endpoint: NWEndpoint) -> (host: String, port: Int)? {
        switch endpoint {
        case .hostPort(let host, let port):
            return (hostString(host), Int(port.rawValue))
        default:
            return nil
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        @unknown default:
            return "\(host)"
        }
    }
}
