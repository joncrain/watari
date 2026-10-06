import Foundation
import Network

struct BonjourPeer: Identifiable, Equatable {
    var id: String { "\(name)-\(host)-\(port)" }
    var name: String
    var host: String
    var port: Int
}

/// Optional Nearby discovery via Bonjour / DNS-SD. Off under managed defaults.
final class BonjourBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private var onUpdate: (([BonjourPeer]) -> Void)?

    /// Bonjour service type for Watari.
    static let serviceType = "_watari._tcp"

    func start(onUpdate: @escaping ([BonjourPeer]) -> Void) {
        stop()
        self.onUpdate = onUpdate
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var peers: [BonjourPeer] = []
            for result in results {
                if case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint {
                    // Resolve happens on connect; advertise name for UI selection.
                    peers.append(BonjourPeer(name: name, host: name, port: 0))
                }
            }
            DispatchQueue.main.async {
                self.onUpdate?(peers)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Advertises this Mac when listen + Nearby discovery are enabled.
final class BonjourAdvertiser: @unchecked Sendable {
    private var listener: NWListener?

    func start(port: Int, name: String) throws {
        stop()
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.service = NWListener.Service(name: name, type: BonjourBrowser.serviceType)
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
