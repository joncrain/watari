import Foundation
import Network
import WatariCore
import CryptoKit

enum PeerConnectorError: LocalizedError {
    case invalidPort
    case handshakeFailed(String)
    case untrustedPeer
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "Invalid port"
        case .handshakeFailed(let s): return "Handshake failed: \(s)"
        case .untrustedPeer: return "Peer public key does not match the pinned key"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Explicit host/port connect + pairing with pinned keys over TLS.
final class PeerConnector: @unchecked Sendable {
    private var connection: NWConnection?
    private let localKey = Curve25519.Signing.PrivateKey()

    var publicKeyData: Data { localKey.publicKey.rawRepresentation }

    func pair(host: String, port: Int, displayName: String, pairingCode: String) async throws -> PeerRecord {
        guard port > 0, port < 65536 else { throw PeerConnectorError.invalidPort }

        let peerKey = try await connectAndExchange(
            host: host,
            port: port,
            pairingCode: pairingCode,
            requirePinned: nil
        )

        return PeerRecord(
            displayName: displayName,
            host: host,
            port: port,
            publicKey: peerKey
        )
    }

    func openTLS(to peer: PeerRecord) async throws -> NWConnection {
        guard let host = peer.host, let port = peer.port else {
            throw PeerConnectorError.handshakeFailed("Peer has no host/port")
        }
        _ = try await connectAndExchange(
            host: host,
            port: port,
            pairingCode: "",
            requirePinned: peer.publicKey.isEmpty ? nil : peer.publicKey
        )
        guard let connection else {
            throw PeerConnectorError.handshakeFailed("No connection")
        }
        return connection
    }

    private func connectAndExchange(
        host: String,
        port: Int,
        pairingCode: String,
        requirePinned: Data?
    ) async throws -> Data {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PeerConnectorError.invalidPort
        }

        // TLS options — pin after pairing using application-level key check on Hello.
        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    cont.resume(throwing: PeerConnectorError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        let hello = HelloPayload(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            displayName: Host.current().localizedName ?? "Watari Mac",
            publicKey: publicKeyData
        )
        var payload = try TransferCodec.encodeJSON(.hello, hello)
        // Append pairing code as a second frame for first-time pair
        if !pairingCode.isEmpty {
            let codeData = Data(pairingCode.utf8)
            payload.append(try TransferCodec.encode(WireFrame(type: .pairChallenge, payload: codeData)))
        }

        try await send(payload, on: connection)
        let frames = FrameBuffer()
        let frame = try await receiveFrame(on: connection, buffer: frames)
        guard frame.type == .hello else {
            throw PeerConnectorError.handshakeFailed("Expected hello")
        }
        let peerHello = try TransferCodec.decodeJSON(frame, as: HelloPayload.self)

        if let requirePinned, !requirePinned.isEmpty, peerHello.publicKey != requirePinned {
            connection.cancel()
            throw PeerConnectorError.untrustedPeer
        }

        return peerHello.publicKey
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func receiveFrame(on connection: NWConnection, buffer: FrameBuffer) async throws -> WireFrame {
        if let ready = try buffer.nextFrame() {
            return ready
        }
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: TransferCodec.maxPayloadSize + 5
                ) { content, _, _, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    guard let data = content, !data.isEmpty else {
                        cont.resume(throwing: PeerConnectorError.handshakeFailed("Empty response"))
                        return
                    }
                    cont.resume(returning: data)
                }
            }
            buffer.append(chunk)
            if let frame = try buffer.nextFrame() {
                return frame
            }
        }
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }
}
