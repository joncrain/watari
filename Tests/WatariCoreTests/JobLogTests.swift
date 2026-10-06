import Foundation
import Testing
import WatariCore

@Suite("JobLog")
struct JobLogTests {
    @Test("fromPreview exports actions and permission exceptions")
    func fromPreview() throws {
        let receiving = ReceivingIdentity(uid: 501, gid: 20, userName: "ada", groupName: "staff")
        let summary = PreviewDiff.build(
            sources: [
                FileMetadata(relativePath: "a.txt", isDirectory: false, size: 3, uid: 502, contentFingerprint: "a"),
            ],
            destinations: [:],
            receiving: receiving
        )
        let log = JobLog.fromPreview(summary, jobId: "job-1", peerId: "peer-1")
        #expect(log.events.contains { $0.action == .copy && $0.path == "a.txt" })
        #expect(log.exceptionEvents.contains { $0.reason == PermissionExceptionCode.ownerRemapped.rawValue })
        let lines = try log.jsonLines()
        #expect(lines.contains("ownerRemapped"))
        #expect(lines.contains("job-1"))
    }
}
