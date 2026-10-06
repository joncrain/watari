import Foundation
import Testing
import WatariCore

@Suite("FrameBuffer")
struct FrameBufferTests {
    @Test("splits concatenated frames from one read")
    func multiFrame() throws {
        var blob = Data()
        blob.append(try TransferCodec.encode(WireFrame(type: .ping, payload: Data([1]))))
        blob.append(try TransferCodec.encode(WireFrame(type: .pong, payload: Data([2, 3]))))
        blob.append(try TransferCodec.encodeJSON(.inventoryRequest, InventoryRequestPayload(rootNames: ["Documents"])))

        let buffer = FrameBuffer()
        buffer.append(blob)
        let a = try buffer.nextFrame()
        let b = try buffer.nextFrame()
        let c = try buffer.nextFrame()
        #expect(a?.type == .ping)
        #expect(b?.type == .pong)
        #expect(b?.payload == Data([2, 3]))
        #expect(c?.type == .inventoryRequest)
        #expect(try buffer.nextFrame() == nil)
        #expect(buffer.pendingByteCount == 0)
    }

    @Test("waits across partial header and payload")
    func partialReads() throws {
        let frame = WireFrame(type: .fileChunk, payload: Data(repeating: 9, count: 40))
        let encoded = try TransferCodec.encode(frame)
        let buffer = FrameBuffer()

        buffer.append(encoded.prefix(3))
        #expect(try buffer.nextFrame() == nil)

        buffer.append(encoded.dropFirst(3).prefix(10))
        #expect(try buffer.nextFrame() == nil)

        buffer.append(encoded.dropFirst(13))
        let decoded = try buffer.nextFrame()
        #expect(decoded == frame)
        #expect(try buffer.nextFrame() == nil)
    }
}
