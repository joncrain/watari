import Testing
import WatariCore

@Suite("DLPPolicy")
struct DLPPolicyTests {
    @Test("disabled policy allows everything")
    func disabled() {
        let policy = DLPPolicy.disabled
        #expect(DLPEngine.evaluateFile(relativePath: "secret.pem", size: 99, policy: policy) == .allow)
        #expect(DLPEngine.evaluateJobDirection(outbound: true, policy: policy) == .allow)
    }

    @Test("blocks extensions and oversized files")
    func blocks() {
        let policy = DLPPolicy(
            enabled: true,
            blockedExtensions: ["pem", "p12"],
            maxFileBytes: 1000,
            blockedNameSubstrings: ["password"]
        )
        #expect(DLPEngine.evaluateFile(relativePath: "certs/prod.pem", size: 10, policy: policy) == .blockExtension)
        #expect(DLPEngine.evaluateFile(relativePath: "big.bin", size: 5000, policy: policy) == .blockSize)
        #expect(DLPEngine.evaluateFile(relativePath: "my-password-notes.txt", size: 10, policy: policy) == .blockName)
        #expect(DLPEngine.evaluateFile(relativePath: "ok.txt", size: 10, policy: policy) == .allow)
    }

    @Test("direction and peer gates")
    func directionPeer() {
        let policy = DLPPolicy(enabled: true, requireAllowlistedPeer: true, blockOutbound: true)
        #expect(DLPEngine.evaluateJobDirection(outbound: true, policy: policy) == .blockOutbound)
        #expect(DLPEngine.evaluatePeer(isAllowlisted: false, policy: policy) == .blockPeerNotAllowlisted)
        #expect(DLPEngine.evaluatePeer(isAllowlisted: true, policy: policy) == .allow)
    }

    @Test("preview skips DLP hits")
    func previewSkip() {
        let receiving = ReceivingIdentity(uid: 501, gid: 20, userName: "ada", groupName: "staff")
        let sources = [
            FileMetadata(relativePath: "ok.txt", isDirectory: false, size: 1),
            FileMetadata(relativePath: "id_rsa.pem", isDirectory: false, size: 1),
        ]
        let dlp = DLPPolicy(enabled: true, blockedExtensions: ["pem"])
        let summary = PreviewDiff.build(sources: sources, dlp: dlp, receiving: receiving)
        #expect(summary.copy == 1)
        #expect(summary.skip == 1)
        #expect(summary.items.first { $0.relativePath == "id_rsa.pem" }?.skipReason == .dlp)
    }
}
