import Foundation
import Network
import WatariCore
import CryptoKit
import os.log

private let peerLog = Logger(subsystem: "app.watari.mac", category: "PeerConnector")

enum PeerConnectorError: LocalizedError {
    case invalidPort
    case handshakeFailed(String)
    case untrustedPeer
    case cancelled
    case notListening
    case localNetworkDenied
    case connectionRefused
    case tlsHandshakeFailed

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid port number."
        case .handshakeFailed(let s):
            return s
        case .untrustedPeer:
            return "That Mac’s key doesn’t match the pinned peer. Remove it and pair again."
        case .cancelled:
            return "Connection cancelled."
        case .notListening:
            return "Couldn’t reach Watari on that Mac. On the source Mac: open Watari → Settings → turn on Listen for peers, and leave the app open."
        case .localNetworkDenied:
            return "Local Network access is off for Watari. System Settings → Privacy & Security → Local Network → enable Watari, then try again."
        case .connectionRefused:
            return "Connection refused. Check the host/port, allow Watari through the firewall if prompted, and confirm Listen is on."
        case .tlsHandshakeFailed:
            return "Secure connection failed (TLS). Update both Macs to the latest Watari, confirm Listen is on, then try again."
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
            throw PeerConnectorError.handshakeFailed("Peer has no host/port.")
        }
        _ = try await connectAndExchange(
            host: host,
            port: port,
            pairingCode: "",
            requirePinned: peer.publicKey.isEmpty ? nil : peer.publicKey
        )
        guard let connection else {
            throw PeerConnectorError.handshakeFailed("No connection.")
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

        let params = WatariTLS.clientParameters()
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = connection

        do {
            try await waitUntilReady(connection)
        } catch {
            connection.cancel()
            throw mapNetworkError(error)
        }

        let hello = HelloPayload(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            displayName: Host.current().localizedName ?? "Watari Mac",
            publicKey: publicKeyData
        )
        var payload = try TransferCodec.encodeJSON(.hello, hello)
        if !pairingCode.isEmpty {
            let codeData = Data(pairingCode.utf8)
            payload.append(try TransferCodec.encode(WireFrame(type: .pairChallenge, payload: codeData)))
        }

        try await send(payload, on: connection)
        let frames = FrameBuffer()
        let frame = try await receiveFrame(on: connection, buffer: frames)
        guard frame.type == .hello else {
            throw PeerConnectorError.handshakeFailed("Expected hello from peer.")
        }
        let peerHello = try TransferCodec.decodeJSON(frame, as: HelloPayload.self)

        if let requirePinned, !requirePinned.isEmpty, peerHello.publicKey != requirePinned {
            connection.cancel()
            throw PeerConnectorError.untrustedPeer
        }

        return peerHello.publicKey
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(PeerConnectorError.cancelled))
                case .waiting(let error):
                    // Surf waiting errors that won't recover (e.g. refused).
                    let ns = error as NWError
                    if case .posix(let code) = ns, code == .ECONNREFUSED {
                        resumeOnce(.failure(error))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func mapNetworkError(_ error: Error) -> PeerConnectorError {
        peerLog.error("Network connect failed: \(error.localizedDescription, privacy: .public)")
        let text = error.localizedDescription
        if let nw = error as? NWError {
            switch nw {
            case .tls(let status):
                // errSSLInternal = -9810
                if status == -9810 || text.contains("-9810") {
                    return .tlsHandshakeFailed
                }
                return .tlsHandshakeFailed
            case .posix(let code):
                if code == .ECONNREFUSED { return .connectionRefused }
                if code == .EHOSTUNREACH || code == .ENETUNREACH { return .notListening }
                break
            default:
                break
            }
        }
        if text.contains("-9810") || text.lowercased().contains("ssl") || text.lowercased().contains("tls") {
            return .tlsHandshakeFailed
        }
        if text.lowercased().contains("refused") {
            return .connectionRefused
        }
        if text.lowercased().contains("local network") || text.contains("-72008") {
            return .localNetworkDenied
        }
        return .handshakeFailed(
            "Couldn’t connect (\(text)). On the source Mac enable Listen, allow Local Network for Watari, and check firewall/port."
        )
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
                        cont.resume(throwing: PeerConnectorError.handshakeFailed("Empty response from peer."))
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
