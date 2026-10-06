import Foundation
import Network
import Security
import CryptoKit
import os.log

private let tlsLog = Logger(subsystem: "app.watari.mac", category: "TLS")

/// Shared TLS options for Watari peer connections.
///
/// Root cause of NWError -9810 (`errSSLInternal`): listener/client used
/// `NWProtocolTLS.Options()` with **no local identity** on the server and default
/// certificate verification on the client, so the handshake failed before Hello.
///
/// Trust model: transport TLS uses a per-install self-signed identity; application
/// trust is still the Curve25519 key exchanged in Hello (pinned after pairing).
enum WatariTLS {
    private static let keychainLabel = "app.watari.mac.tls-identity"
    private static let queue = DispatchQueue(label: "app.watari.mac.tls")

    /// Identity for this Mac’s listener (created once, stored in keychain).
    private static let localIdentity: SecIdentity? = {
        if let existing = loadIdentity() { return existing }
        do {
            return try createAndStoreIdentity()
        } catch {
            tlsLog.error("Failed to create TLS identity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func listenerParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if let identity = localIdentity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        } else {
            tlsLog.error("Listener starting without TLS identity — handshake will fail (-9810)")
        }
        // Peer authentication is application-level (Hello public key pin).
        sec_protocol_options_set_peer_authentication_required(security, false)
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true
        return params
    }

    static func clientParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        // Accept the peer’s self-signed transport cert; pin via Hello afterward.
        sec_protocol_options_set_verify_block(security, { _, _, completion in
            completion(true)
        }, queue)
        sec_protocol_options_set_peer_authentication_required(security, false)
        let tcp = NWProtocolTCP.Options()
        return NWParameters(tls: tls, tcp: tcp)
    }

    // MARK: - Identity lifecycle

    private static func loadIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        // swiftlint:disable:next force_cast
        return (item as! SecIdentity)
    }

    private static func createAndStoreIdentity() throws -> SecIdentity {
        let tag = "\(keychainLabel).key".data(using: .utf8)!
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: keychainLabel,
            kSecAttrApplicationTag as String: tag,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            throw TLSIdentityError.keyed(error?.takeRetainedValue().localizedDescription ?? "key create failed")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw TLSIdentityError.keyed("missing public key")
        }
        let cert = try SelfSignedCertificate.make(for: publicKey, privateKey: privateKey, commonName: "Watari Peer")

        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: keychainLabel,
        ]
        SecItemDelete(certAdd as CFDictionary)
        var status = SecItemAdd(certAdd as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TLSIdentityError.keyed("cert store \(status)")
        }

        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Prefer finding identity by certificate
        let byCert: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecValueRef as String: cert,
        ]
        var identityRef: CFTypeRef?
        status = SecItemCopyMatching(byCert as CFDictionary, &identityRef)
        if status != errSecSuccess {
            status = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)
        }
        if status == errSecSuccess, let identityRef {
            return (identityRef as! SecIdentity)
        }

        // macOS: build identity from cert + keychain private key.
        var created: SecIdentity?
        let createStatus = SecIdentityCreateWithCertificate(nil, cert, &created)
        guard createStatus == errSecSuccess, let created else {
            throw TLSIdentityError.keyed("identity create \(createStatus) / lookup \(status)")
        }
        return created
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

// MARK: - Minimal self-signed X.509 (ECDSA P-256)

/// Builds a tiny self-signed certificate so Network.framework TLS has a local identity.
enum SelfSignedCertificate {
    static func make(for publicKey: SecKey, privateKey: SecKey, commonName: String) throws -> SecCertificate {
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TLSIdentityError.keyed("export public key")
        }
        // ANSI X9.63 uncompressed: 0x04 || X || Y (65 bytes for P-256)
        guard publicKeyData.count == 65, publicKeyData[0] == 0x04 else {
            throw TLSIdentityError.keyed("unexpected EC public key format")
        }

        let serial = Data([0x01])
        let cnData = Data(commonName.utf8)
        let notBefore = Date()
        let notAfter = Calendar.current.date(byAdding: .year, value: 10, to: notBefore) ?? notBefore.addingTimeInterval(86400 * 3650)

        let tbs = try tbsCertificate(
            serial: serial,
            cn: cnData,
            notBefore: notBefore,
            notAfter: notAfter,
            publicKeyX963: publicKeyData
        )

        let digest = SHA256.hash(data: tbs)
        let digestData = Data(digest)
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &signError
        ) as Data? else {
            throw TLSIdentityError.keyed(signError?.takeRetainedValue().localizedDescription ?? "sign failed")
        }
        _ = digestData

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        let cert = asn1Sequence(
            tbs
            + asn1Sequence(oidECDSAWithSHA256)
            + asn1BitString(signature)
        )
        guard let certificate = SecCertificateCreateWithData(nil, cert as CFData) else {
            throw TLSIdentityError.keyed("SecCertificateCreateWithData failed")
        }
        return certificate
    }

    // MARK: ASN.1 helpers

    private static let oidECDSAWithSHA256 = Data([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
    private static let oidECPublicKey = Data([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
    private static let oidPrime256v1 = Data([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
    private static let oidCommonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])

    private static func tbsCertificate(
        serial: Data,
        cn: Data,
        notBefore: Date,
        notAfter: Date,
        publicKeyX963: Data
    ) throws -> Data {
        // Version v3 (explicit [0] EXPLICIT INTEGER 2)
        let version = Data([0xa0, 0x03, 0x02, 0x01, 0x02])
        let serialNumber = asn1Integer(serial)
        let signature = asn1Sequence(oidECDSAWithSHA256)
        let issuer = asn1Name(cn: cn)
        let validity = asn1Sequence(asn1UTCTime(notBefore) + asn1UTCTime(notAfter))
        let subject = issuer
        let algorithm = asn1Sequence(oidECPublicKey + oidPrime256v1)
        let subjectPublicKeyInfo = asn1Sequence(algorithm + asn1BitString(publicKeyX963))
        return asn1Sequence(
            version + serialNumber + signature + issuer + validity + subject + subjectPublicKeyInfo
        )
    }

    private static func asn1Name(cn: Data) -> Data {
        // Name ::= RDNSequence ::= SEQUENCE OF RelativeDistinguishedName
        // RDN ::= SET OF AttributeTypeAndValue
        let attr = asn1Sequence(oidCommonName + asn1UTF8String(cn))
        let rdn = asn1Set(attr)
        return asn1Sequence(rdn)
    }

    private static func asn1UTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let s = formatter.string(from: date)
        var d = Data([0x17, UInt8(s.utf8.count)])
        d.append(contentsOf: s.utf8)
        return d
    }

    private static func asn1UTF8String(_ data: Data) -> Data {
        asn1Header(0x0c, length: data.count) + data
    }

    private static func asn1Integer(_ data: Data) -> Data {
        var value = data
        if let first = value.first, first >= 0x80 {
            value.insert(0x00, at: 0)
        }
        return asn1Header(0x02, length: value.count) + value
    }

    private static func asn1BitString(_ data: Data) -> Data {
        var content = Data([0x00]) // unused bits
        content.append(data)
        return asn1Header(0x03, length: content.count) + content
    }

    private static func asn1Sequence(_ data: Data) -> Data {
        asn1Header(0x30, length: data.count) + data
    }

    private static func asn1Set(_ data: Data) -> Data {
        asn1Header(0x31, length: data.count) + data
    }

    private static func asn1Header(_ tag: UInt8, length: Int) -> Data {
        var d = Data([tag])
        if length < 0x80 {
            d.append(UInt8(length))
        } else if length <= 0xff {
            d.append(contentsOf: [0x81, UInt8(length)])
        } else {
            d.append(contentsOf: [0x82, UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        }
        return d
    }
}
