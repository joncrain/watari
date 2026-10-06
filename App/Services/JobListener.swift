import Foundation
import Network
import WatariCore
import os.log

private let listenLog = Logger(subsystem: "app.watari.mac", category: "JobListener")

/// Accepts inbound TLS: offer catalog / pull (source) and push jobs (destination).
final class JobListener: @unchecked Sendable {
    private var listener: NWListener?
    private let transfer = TransferSession()
    private let identityKey: () -> Data
    private let displayName: () -> String

    init(identityKey: @escaping () -> Data, displayName: @escaping () -> String) {
        self.identityKey = identityKey
        self.displayName = displayName
    }

    var isListening: Bool { listener != nil }

    func start(
        port: Int,
        receiveRoot: URL?,
        offeredRoots: [String: URL],
        offerCatalog: OfferCatalogResponsePayload,
        advertiseBonjour: Bool,
        applier: PermissionApplier,
        onIndexUpdate: @escaping @Sendable ([FileMetadata]) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PeerConnectorError.invalidPort
        }

        let params = WatariTLS.listenerParameters()
        let listener = try NWListener(using: params, on: nwPort)
        if advertiseBonjour {
            let name = displayName()
            listener.service = NWListener.Service(name: name, type: BonjourBrowser.serviceType)
            listenLog.info("Advertising Bonjour \(BonjourBrowser.serviceType, privacy: .public) as \(name, privacy: .public)")
        }

        let catalog = offerCatalog
        let offered = offeredRoots
        let receive = receiveRoot
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                do {
                    try await self.transfer.serve(
                        on: connection,
                        receiveRoot: receive,
                        offeredRoots: offered,
                        offerCatalog: catalog,
                        identityKey: self.identityKey(),
                        displayName: self.displayName(),
                        applier: applier,
                        onIndexUpdate: onIndexUpdate,
                        progress: { _, _ in }
                    )
                } catch {
                    onError(error.localizedDescription)
                }
                connection.cancel()
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listenLog.info("Listening on port \(port)")
            case .failed(let error):
                listenLog.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                onError(error.localizedDescription)
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        transfer.cancel()
    }
}
