import Foundation

/// Accumulates TCP reads and yields complete Watari frames (partial + multi-frame safe).
public final class FrameBuffer: @unchecked Sendable {
    private var buffer = Data()

    public init() {}

    public var pendingByteCount: Int { buffer.count }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
    }

    /// Pop the next complete frame, or `nil` if more bytes are needed.
    public func nextFrame() throws -> WireFrame? {
        try TransferCodec.decode(from: &buffer)
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
