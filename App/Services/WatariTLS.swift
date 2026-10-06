import Foundation
import Network
import Security
import os.log

private let tlsLog = Logger(subsystem: "app.watari.mac", category: "TLS")

/// Shared TLS options for Watari peer connections.
///
/// Transport identity lives in an **app-owned file keychain** under Application Support
/// (`Watari/tls.keychain`) plus a PKCS#12 seed. Nothing is read from or written to the
/// login keychain — that path previously prompted for the user’s Apple Development
/// (“dev”) key when a loose `kSecClassIdentity` query resolved the wrong SecIdentity,
/// and failed handshakes with NWError -9816.
///
/// Application trust remains the Curve25519 key exchanged in Hello (pinned after pairing).
enum WatariTLS {
    private static let queue = DispatchQueue(label: "app.watari.mac.tls")
    private static let legacyKeychainLabel = "app.watari.mac.tls-identity"
    /// Filename bumped when switching RSA — LibreSSL EC PKCS#12 crashes SecPKCS12Import on current macOS.
    private static let p12FileName = "tls-identity-rsa.p12"
    private static let passphraseFileName = "tls-identity-rsa.pass"
    private static let fileKeychainName = "tls-rsa.keychain"

    nonisolated(unsafe) private static let localIdentity: SecIdentity? = {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }

        deleteLegacyLoginKeychainItems()
        deleteLegacyECIdentityFiles()

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

    // MARK: - App-owned file keychain + PKCS#12

    private static func loadOrCreateIdentity() throws -> SecIdentity {
        let dir = try supportDirectory()
        let passURL = dir.appendingPathComponent(passphraseFileName)
        let p12URL = dir.appendingPathComponent(p12FileName)
        let keychainURL = dir.appendingPathComponent(fileKeychainName)

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

        let keychain = try openFileKeychain(at: keychainURL, passphrase: passphrase)
        if let existing = copyIdentity(from: keychain) {
            tlsLog.info("TLS identity ready (existing file keychain item)")
            return existing
        }
        return try importPKCS12(from: p12URL, passphrase: passphrase, into: keychain)
    }

    private static func copyIdentity(from keychain: SecKeychain) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchSearchList as String: [keychain],
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        return (item as! SecIdentity)
    }

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Watari", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func openFileKeychain(at url: URL, passphrase: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let path = url.path
        let pwd = passphrase
        let pwdLen = UInt32(pwd.utf8.count)

        if FileManager.default.fileExists(atPath: path) {
            var status = SecKeychainOpen(path, &keychain)
            guard status == errSecSuccess, let keychain else {
                throw TLSIdentityError.keyed("keychain open \(status)")
            }
            status = SecKeychainUnlock(keychain, pwdLen, pwd, true)
            if status != errSecSuccess && status != errSecAuthFailed {
                // Retry after recreate if unlock fails hard.
                tlsLog.error("Keychain unlock \(status) — recreating")
                try? FileManager.default.removeItem(at: url)
                return try createFileKeychain(at: url, passphrase: passphrase)
            }
            if status == errSecAuthFailed {
                try? FileManager.default.removeItem(at: url)
                return try createFileKeychain(at: url, passphrase: passphrase)
            }
            return keychain
        }
        return try createFileKeychain(at: url, passphrase: passphrase)
    }

    private static func createFileKeychain(at url: URL, passphrase: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let pwd = passphrase
        let status = SecKeychainCreate(
            url.path,
            UInt32(pwd.utf8.count),
            pwd,
            false,
            nil,
            &keychain
        )
        guard status == errSecSuccess || status == errSecDuplicateKeychain, let keychain else {
            throw TLSIdentityError.keyed("keychain create \(status)")
        }
        if status == errSecDuplicateKeychain {
            return try openFileKeychain(at: url, passphrase: passphrase)
        }
        // Avoid any ACL prompts on keys stored here.
        SecKeychainSetUserInteractionAllowed(false)
        return keychain
    }

    private static func importPKCS12(from url: URL, passphrase: String, into keychain: SecKeychain) throws -> SecIdentity {
        let data = try Data(contentsOf: url)
        var items: CFArray?
        // Import into the Watari file keychain only — never login keychain, never memory-only
        // (memory-only PKCS12 import crashes on some macOS builds with NULL SecKeyRef).
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportExportKeychain as String: keychain,
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let items = items as? [[String: Any]], let first = items.first else {
            throw TLSIdentityError.keyed("PKCS12 import \(status)")
        }
        guard let identity = first[kSecImportItemIdentity as String] else {
            throw TLSIdentityError.keyed("PKCS12 missing identity")
        }
        tlsLog.info("TLS identity ready (Application Support file keychain)")
        return identity as! SecIdentity
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

    /// Drop EC PKCS#12 / keychain from the first TLS fix (import crashed with NULL SecKeyRef).
    private static func deleteLegacyECIdentityFiles() {
        guard let dir = try? supportDirectory() else { return }
        for name in [
            "tls-identity.p12", "tls-identity.pass", "tls.keychain", "tls.keychain-db",
            "tls-tmp-key.pem", "tls-tmp-cert.pem",
        ] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
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
