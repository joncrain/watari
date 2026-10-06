import Foundation
import Network
import WatariCore

/// Accepts inbound TLS jobs and inventory requests.
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
        destinationRoot: URL,
        applier: PermissionApplier,
        onIndexUpdate: @escaping ([FileMetadata]) -> Void,
        onError: @escaping (String) -> Void
    ) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PeerConnectorError.invalidPort
        }
        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                do {
                    try await self.transfer.serve(
                        on: connection,
                        destinationRoot: destinationRoot,
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
            if case .failed(let error) = state {
                onError(error.localizedDescription)
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
