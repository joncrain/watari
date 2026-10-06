import Foundation

/// Calm post-job summary for the destination Mac.
struct TransferCompleteSummary: Equatable {
    var peerDisplayName: String
    var folderNames: [String]
    var filesTransferred: Int
    var bytesTransferred: UInt64
    var durationSeconds: TimeInterval
    var skipped: Int
    var unchanged: Int
    var permissionRemaps: Int
    var permissionNotes: Int
    var hadExceptions: Bool

    var durationLabel: String {
        if durationSeconds < 1 {
            return "< 1s"
        }
        if durationSeconds < 60 {
            return String(format: "%.0fs", durationSeconds)
        }
        let minutes = Int(durationSeconds) / 60
        let seconds = Int(durationSeconds) % 60
        return "\(minutes)m \(seconds)s"
    }

    var bytesLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesTransferred), countStyle: .file)
    }
}
