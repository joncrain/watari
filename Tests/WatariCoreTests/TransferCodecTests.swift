import Foundation
import Testing
import WatariCore

@Suite("TransferCodec")
struct TransferCodecTests {
    @Test("round-trips frames")
    func roundTrip() throws {
        let frame = WireFrame(type: .ping, payload: Data("watari".utf8))
        var encoded = try TransferCodec.encode(frame)
        let decoded = try TransferCodec.decode(from: &encoded)
        #expect(decoded == frame)
        #expect(encoded.isEmpty)
    }

    @Test("streams multiple frames")
    func multiple() throws {
        var buffer = Data()
        buffer.append(try TransferCodec.encode(WireFrame(type: .ping, payload: Data([1]))))
        buffer.append(try TransferCodec.encode(WireFrame(type: .pong, payload: Data([2]))))
        let first = try TransferCodec.decode(from: &buffer)
        let second = try TransferCodec.decode(from: &buffer)
        #expect(first?.type == .ping)
        #expect(second?.type == .pong)
        #expect(buffer.isEmpty)
    }

    @Test("JSON hello over in-memory transport")
    func inMemoryHello() async throws {
        let hello = HelloPayload(appVersion: "0.1.0", displayName: "Mac A", publicKey: Data([9, 9, 9]))
        let bytes = try TransferCodec.encodeJSON(.hello, hello)
        let transport = InMemoryTransport()
        await transport.sendAtoB(bytes)
        let frame = try await transport.receiveB()
        #expect(frame?.type == .hello)
        let decoded = try TransferCodec.decodeJSON(frame!, as: HelloPayload.self)
        #expect(decoded.displayName == "Mac A")
        #expect(decoded.publicKey == Data([9, 9, 9]))
    }

    @Test("connection profile JSON")
    func connectionProfile() throws {
        let profile = ConnectionProfile(displayName: "Lab B", host: "mac-b.lab", port: 59234)
        let data = try profile.exportJSON()
        let back = try ConnectionProfile.importJSON(data)
        #expect(back.host == "mac-b.lab")
        #expect(back.port == 59234)
    }
}
