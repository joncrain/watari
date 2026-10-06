import Foundation

public enum JobLogAction: String, Codable, Sendable {
    case copy
    case update
    case keepBoth
    case skip
    case unchanged
    case exception
}

public struct JobLogEvent: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var jobId: String
    public var peerId: String
    public var path: String
    public var action: JobLogAction
    public var reason: String?
    public var bytes: UInt64?
    public var permissionDelta: String?

    public init(
        timestamp: Date = Date(),
        jobId: String,
        peerId: String,
        path: String,
        action: JobLogAction,
        reason: String? = nil,
        bytes: UInt64? = nil,
        permissionDelta: String? = nil
    ) {
        self.timestamp = timestamp
        self.jobId = jobId
        self.peerId = peerId
        self.path = path
        self.action = action
        self.reason = reason
        self.bytes = bytes
        self.permissionDelta = permissionDelta
    }
}

public struct JobLog: Sendable {
    public private(set) var events: [JobLogEvent]

    public init(events: [JobLogEvent] = []) {
        self.events = events
    }

    public mutating func append(_ event: JobLogEvent) {
        events.append(event)
    }

    public var exceptionEvents: [JobLogEvent] {
        events.filter { $0.action == .exception }
    }

    public func jsonLines() throws -> String {
        let encoder = JSONEncoder.watari
        var lines: [String] = []
        for event in events {
            let data = try encoder.encode(event)
            guard let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public func jsonLinesData() throws -> Data {
        Data((try jsonLines()).utf8)
    }

    /// Build an audit log from a Preview summary (actions + permission exceptions).
    public static func fromPreview(
        _ summary: PreviewSummary,
        jobId: String,
        peerId: String,
        timestamp: Date = Date()
    ) -> JobLog {
        var log = JobLog()
        for item in summary.items {
            let action: JobLogAction
            switch item.action {
            case .copy: action = .copy
            case .update: action = .update
            case .keepBoth: action = .keepBoth
            case .skip: action = .skip
            case .unchanged: action = .unchanged
            }
            log.append(
                JobLogEvent(
                    timestamp: timestamp,
                    jobId: jobId,
                    peerId: peerId,
                    path: item.relativePath,
                    action: action,
                    reason: item.skipReason?.rawValue,
                    bytes: item.source?.size,
                    permissionDelta: nil
                )
            )
            for ex in item.permissionExceptions {
                log.append(
                    JobLogEvent(
                        timestamp: timestamp,
                        jobId: jobId,
                        peerId: peerId,
                        path: item.relativePath,
                        action: .exception,
                        reason: ex.code.rawValue,
                        bytes: nil,
                        permissionDelta: ex.detail
                    )
                )
            }
        }
        return log
    }
}
