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
    case timedOut

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
            return "Connection refused. Confirm Listen is on for that Mac and the port matches. (This is usually “nothing listening”, not the macOS firewall.)"
        case .tlsHandshakeFailed:
            return "Secure connection failed (TLS). Update both Macs to the latest Watari, confirm Listen is on, then try again."
        case .timedOut:
            return "Timed out reaching that Mac. Confirm Listen is on, both Macs share a network path, and Local Network is allowed for Watari."
        }
    }
}

/// Explicit host/port or Bonjour-service connect + pairing with pinned keys over TLS.
final class PeerConnector: @unchecked Sendable {
    private var connection: NWConnection?
    private let localKey = Curve25519.Signing.PrivateKey()

    var publicKeyData: Data { localKey.publicKey.rawRepresentation }

    func pair(host: String, port: Int, displayName: String, pairingCode: String) async throws -> PeerRecord {
        guard port > 0, port < 65536 else { throw PeerConnectorError.invalidPort }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let (peerKey, resolved, _) = try await connectAndExchange(
            to: endpoint,
            pairingCode: pairingCode,
            requirePinned: nil,
            keepOpen: false
        )
        return PeerRecord(
            displayName: displayName,
            host: resolved.host ?? host,
            port: resolved.port ?? port,
            publicKey: peerKey
        )
    }

    /// Nearby: connect via Bonjour service endpoint so Network.framework picks the best path.
    func pair(bonjour peer: BonjourPeer, pairingCode: String = "") async throws -> PeerRecord {
        let (peerKey, resolved, _) = try await connectAndExchange(
            to: peer.endpoint,
            pairingCode: pairingCode,
            requirePinned: nil,
            keepOpen: false
        )
        return PeerRecord(
            displayName: peer.name,
            host: resolved.host,
            port: resolved.port ?? 59234,
            publicKey: peerKey
        )
    }

    /// Pair and leave the TLS socket open for an immediate follow-up (offer catalog).
    func pairKeepingConnection(
        host: String,
        port: Int,
        displayName: String,
        pairingCode: String = ""
    ) async throws -> (PeerRecord, NWConnection) {
        guard port > 0, port < 65536 else { throw PeerConnectorError.invalidPort }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let (peerKey, resolved, connection) = try await connectAndExchange(
            to: endpoint,
            pairingCode: pairingCode,
            requirePinned: nil,
            keepOpen: true
        )
        let record = PeerRecord(
            displayName: displayName.isEmpty ? host : displayName,
            host: resolved.host ?? host,
            port: resolved.port ?? port,
            publicKey: peerKey
        )
        return (record, connection)
    }

    func pairKeepingConnection(bonjour peer: BonjourPeer, pairingCode: String = "") async throws -> (PeerRecord, NWConnection) {
        let (peerKey, resolved, connection) = try await connectAndExchange(
            to: peer.endpoint,
            pairingCode: pairingCode,
            requirePinned: nil,
            keepOpen: true
        )
        let record = PeerRecord(
            displayName: peer.name,
            host: resolved.host,
            port: resolved.port ?? 59234,
            publicKey: peerKey
        )
        return (record, connection)
    }

    func openTLS(to peer: PeerRecord) async throws -> NWConnection {
        guard let host = peer.host, let port = peer.port else {
            throw PeerConnectorError.handshakeFailed("Peer has no host/port.")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let (_, _, connection) = try await connectAndExchange(
            to: endpoint,
            pairingCode: "",
            requirePinned: peer.publicKey.isEmpty ? nil : peer.publicKey,
            keepOpen: true
        )
        return connection
    }

    private func connectAndExchange(
        to endpoint: NWEndpoint,
        pairingCode: String,
        requirePinned: Data?,
        keepOpen: Bool
    ) async throws -> (Data, (host: String?, port: Int?), NWConnection) {
        // Drop any prior socket so pair()+catalog cannot orphan a Hello’d connection.
        if let previous = connection {
            previous.cancel()
            connection = nil
        }

        let params = WatariTLS.clientParameters()
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection

        do {
            try await waitUntilReady(connection)
        } catch {
            connection.cancel()
            self.connection = nil
            throw mapNetworkError(error)
        }

        let resolved = Self.hostPort(from: connection.currentPath?.remoteEndpoint)

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
            connection.cancel()
            self.connection = nil
            throw PeerConnectorError.handshakeFailed("Expected hello from peer.")
        }
        let peerHello = try TransferCodec.decodeJSON(frame, as: HelloPayload.self)

        if let requirePinned, !requirePinned.isEmpty, peerHello.publicKey != requirePinned {
            connection.cancel()
            self.connection = nil
            throw PeerConnectorError.untrustedPeer
        }

        if !keepOpen {
            connection.cancel()
            self.connection = nil
        }

        return (peerHello.publicKey, resolved, connection)
    }

    /// Wait for `.ready` only. Do **not** fail on `.waiting(ECONNREFUSED)` —
    /// Happy Eyeballs often reports refused on one candidate while another path
    /// (seen in logs as parallel C11 TLS success + C12 refused) is still connecting.
    private func waitUntilReady(_ connection: NWConnection, timeoutSeconds: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class Gate: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                private var timeoutItem: DispatchWorkItem?

                func resume(_ result: Result<Void, Error>, cont: CheckedContinuation<Void, Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    timeoutItem?.cancel()
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }

                func armTimeout(seconds: TimeInterval, cont: CheckedContinuation<Void, Error>, connection: NWConnection) {
                    let item = DispatchWorkItem { [weak self] in
                        connection.cancel()
                        self?.resume(.failure(PeerConnectorError.timedOut), cont: cont)
                    }
                    timeoutItem = item
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
                }
            }
            let gate = Gate()
            gate.armTimeout(seconds: timeoutSeconds, cont: cont, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(.success(()), cont: cont)
                case .failed(let error):
                    gate.resume(.failure(error), cont: cont)
                case .cancelled:
                    gate.resume(.failure(PeerConnectorError.cancelled), cont: cont)
                case .waiting(let error):
                    // Log only — Happy Eyeballs may recover on another path.
                    peerLog.info("Connect waiting: \(error.localizedDescription, privacy: .public)")
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func mapNetworkError(_ error: Error) -> PeerConnectorError {
        peerLog.error("Network connect failed: \(error.localizedDescription, privacy: .public)")
        if let known = error as? PeerConnectorError { return known }
        let text = error.localizedDescription
        if let nw = error as? NWError {
            switch nw {
            case .tls(let status):
                // -9810 errSSLInternal, -9816 errSSLBadCipherSuite (often cleartext→TLS or bad identity)
                if status == -9810 || status == -9816 || text.contains("-9810") || text.contains("-9816") {
                    return .tlsHandshakeFailed
                }
                return .tlsHandshakeFailed
            case .posix(let code):
                if code == .ECONNREFUSED { return .connectionRefused }
                if code == .EHOSTUNREACH || code == .ENETUNREACH { return .notListening }
                if code == .ETIMEDOUT { return .timedOut }
                break
            default:
                break
            }
        }
        if text.contains("-9810") || text.contains("-9816")
            || text.lowercased().contains("ssl") || text.lowercased().contains("tls") {
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

    private static func hostPort(from endpoint: NWEndpoint?) -> (host: String?, port: Int?) {
        guard let endpoint else { return (nil, nil) }
        switch endpoint {
        case .hostPort(let host, let port):
            return (hostString(host), Int(port.rawValue))
        default:
            return (nil, nil)
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
