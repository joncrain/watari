import Foundation
import Network
import Security
import os.log

private let tlsLog = Logger(subsystem: "app.watari.mac", category: "TLS")

/// Shared TLS options for Watari peer connections.
///
/// Transport identity is a self-signed **RSA** PKCS#12 under Application Support, imported
/// **in-process only** (`kSecImportToMemoryOnly`) — never the login keychain and never a
/// file keychain. File keychains prompted for a password Jon never chose (`tls-rsa.keychain`);
/// memory-only identities need no unlock UI.
///
/// Application trust remains the Curve25519 key exchanged in Hello (pinned after pairing).
enum WatariTLS {
    private static let queue = DispatchQueue(label: "app.watari.mac.tls")
    private static let legacyKeychainLabel = "app.watari.mac.tls-identity"
    /// Filename bumped when switching RSA — LibreSSL EC PKCS#12 crashes SecPKCS12Import on current macOS.
    private static let p12FileName = "tls-identity-rsa.p12"
    private static let passphraseFileName = "tls-identity-rsa.pass"

    /// Strong refs so the in-memory PKCS#12 identity outlives import.
    nonisolated(unsafe) private static var retainedImportItems: CFArray?
    nonisolated(unsafe) private static let localIdentity: SecIdentity? = {
        // Never show keychain password / ACL sheets for transport TLS.
        SecKeychainSetUserInteractionAllowed(false)

        deleteLegacyLoginKeychainItems()
        deleteLegacyKeychainFiles()

        do {
            return try loadOrCreateIdentity()
        } catch {
            tlsLog.error("Failed to create TLS identity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static var hasIdentity: Bool { localIdentity != nil }

    static func listenerParameters() throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        guard let identity = localIdentity, let secIdentity = sec_identity_create(identity) else {
            tlsLog.error("No TLS identity — refusing to start listener (-9810/-9816)")
            throw TLSIdentityError.keyed("missing local identity")
        }
        sec_protocol_options_set_local_identity(security, secIdentity)
        sec_protocol_options_set_peer_authentication_required(security, false)
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true
        return params
    }

    static func clientParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_verify_block(security, { _, _, completion in
            completion(true)
        }, queue)
        sec_protocol_options_set_peer_authentication_required(security, false)
        let tcp = NWProtocolTCP.Options()
        return NWParameters(tls: tls, tcp: tcp)
    }

    // MARK: - PKCS#12 on disk → in-memory SecIdentity (no keychain)

    private static func loadOrCreateIdentity() throws -> SecIdentity {
        let dir = try supportDirectory()
        let passURL = dir.appendingPathComponent(passphraseFileName)
        let p12URL = dir.appendingPathComponent(p12FileName)

        let passphrase: String
        if let existing = try? String(contentsOf: passURL, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passphrase = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            passphrase = UUID().uuidString
            try passphrase.write(to: passURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passURL.path)
        }

        if !FileManager.default.fileExists(atPath: p12URL.path) {
            try generatePKCS12(at: p12URL, passphrase: passphrase)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        }

        return try importPKCS12ToMemory(from: p12URL, passphrase: passphrase)
    }

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Watari", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func importPKCS12ToMemory(from url: URL, passphrase: String) throws -> SecIdentity {
        let data = try Data(contentsOf: url)
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let items else {
            throw TLSIdentityError.keyed("PKCS12 memory import \(status)")
        }
        guard let dicts = items as? [[String: Any]],
              let first = dicts.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw TLSIdentityError.keyed("PKCS12 missing identity")
        }
        let identity = identityRef as! SecIdentity

        // Retain the import array for process lifetime (identity refs into it).
        retainedImportItems = items

        // Sanity: private key must be usable without a keychain unlock.
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let privateKey,
              SecKeyCopyExternalRepresentation(privateKey, nil) != nil else {
            throw TLSIdentityError.keyed("memory identity has unusable private key (\(keyStatus))")
        }
        if sec_identity_create(identity) == nil {
            throw TLSIdentityError.keyed("sec_identity_create failed for memory identity")
        }

        tlsLog.info("TLS identity ready (in-memory PKCS12; no file keychain)")
        return identity
    }

    private static func generatePKCS12(at p12URL: URL, passphrase: String) throws {
        let dir = p12URL.deletingLastPathComponent()
        let keyURL = dir.appendingPathComponent("tls-tmp-key.pem")
        let certURL = dir.appendingPathComponent("tls-tmp-cert.pem")
        defer {
            try? FileManager.default.removeItem(at: keyURL)
            try? FileManager.default.removeItem(at: certURL)
        }

        // RSA — LibreSSL EC PKCS#12 triggers SecPKCS12Import crash
        // (`SecKeyCopyExternalRepresentation called with NULL SecKeyRef`) on current macOS.
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "3650",
            "-nodes",
            "-subj", "/CN=Watari Peer",
        ])
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(passphrase)",
            "-name", "Watari Peer",
        ])
        guard FileManager.default.fileExists(atPath: p12URL.path) else {
            throw TLSIdentityError.keyed("openssl did not write PKCS12")
        }
        tlsLog.info("Created Application Support TLS PKCS12")
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TLSIdentityError.keyed("openssl launch: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TLSIdentityError.keyed("openssl \(arguments.first ?? "") failed: \(msg)")
        }
    }

    /// Drop EC PKCS#12 **and** any file keychains from earlier TLS fixes (those prompted for a password).
    private static func deleteLegacyKeychainFiles() {
        guard let dir = try? supportDirectory() else { return }
        for name in [
            "tls-identity.p12", "tls-identity.pass",
            "tls.keychain", "tls.keychain-db",
            "tls-rsa.keychain", "tls-rsa.keychain-db",
            "tls-tmp-key.pem", "tls-tmp-cert.pem",
        ] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                tlsLog.info("Removed legacy TLS file \(name, privacy: .public)")
            }
        }
    }

    /// Remove leftover permanent login-keychain items from earlier builds.
    private static func deleteLegacyLoginKeychainItems() {
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: legacyKeychainLabel],
            [kSecClass as String: kSecClassKey, kSecAttrLabel as String: legacyKeychainLabel],
            [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: "\(legacyKeychainLabel).key".data(using: .utf8)!,
            ],
            [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: legacyKeychainLabel],
        ]
        for query in queries {
            if SecItemDelete(query as CFDictionary) == errSecSuccess {
                tlsLog.info("Removed legacy login-keychain TLS item")
            }
        }
    }
}

enum TLSIdentityError: LocalizedError {
    case keyed(String)
    var errorDescription: String? {
        switch self {
        case .keyed(let s): return "TLS identity: \(s)"
        }
    }
}
