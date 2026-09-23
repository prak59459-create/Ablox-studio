import XCTest
@testable import AbloxCore

final class WireFormatTests: XCTestCase {

    private let peer = PeerID(UUID(uuidString: "11112222-3333-4444-5555-666677778888")!)

    // MARK: PeerID

    func testPeerIDByteRoundTrip() {
        let restored = PeerID(bytes: peer.bytes)
        XCTAssertEqual(restored, peer)
        XCTAssertEqual(peer.bytes.count, 16)
    }

    func testPeerIDRejectsWrongByteCount() {
        XCTAssertNil(PeerID(bytes: []))
        XCTAssertNil(PeerID(bytes: Array(repeating: 0, count: 15)))
        XCTAssertNil(PeerID(bytes: Array(repeating: 0, count: 17)))
    }

    func testPeerIDEncodesAsBareUUIDString() throws {
        let data = try JSONEncoder().encode(["p": peer])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("11112222-3333-4444-5555-666677778888"), text)
    }

    // MARK: Header

    func testHeaderRoundTrip() throws {
        let header = PacketHeader(
            kind: .playerTransform,
            senderID: peer,
            sequence: 0xDEAD_BEEF,
            timestampMilliseconds: 1_700_000_000_123,
            payloadLength: 4096
        )
        let bytes = header.encoded()
        XCTAssertEqual(bytes.count, PacketHeader.encodedSize)

        let decoded = try XCTUnwrap(PacketHeader(decoding: bytes))
        XCTAssertEqual(decoded, header)
    }

    func testHeaderRejectsShortBuffer() {
        let full = PacketHeader(kind: .ping, senderID: peer, sequence: 1, timestampMilliseconds: 1, payloadLength: 0).encoded()
        XCTAssertNil(PacketHeader(decoding: full.prefix(PacketHeader.encodedSize - 1)))
    }

    func testHeaderRejectsUnknownKind() {
        var bytes = PacketHeader(kind: .ping, senderID: peer, sequence: 1, timestampMilliseconds: 1, payloadLength: 0).encoded()
        bytes[0] = 0xFE // not a PacketKind
        XCTAssertNil(PacketHeader(decoding: bytes))
    }

    func testHeaderIsBigEndianOnTheWire() {
        let header = PacketHeader(kind: .ping, senderID: peer, sequence: 1, timestampMilliseconds: 0, payloadLength: 0)
        let bytes = [UInt8](header.encoded())
        // sequence occupies bytes 17..<21; big-endian 1 is 00 00 00 01.
        XCTAssertEqual(Array(bytes[17..<21]), [0, 0, 0, 1])
    }

    // MARK: Codec

    func testCodecRoundTripsPayload() throws {
        let codec = PacketCodec(localPeerID: peer)
        let payload = ChatPayload(senderName: "Taro", text: "hello")
        let packet = try codec.encode(.chat, payload)

        XCTAssertEqual(packet.kind, .chat)
        XCTAssertEqual(packet.senderID, peer)
        XCTAssertEqual(Int(packet.header.payloadLength), packet.payload.count)

        let decoded: ChatPayload = try codec.decodePayload(ChatPayload.self, from: packet)
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertEqual(decoded.senderName, "Taro")
    }

    func testSequenceIncrementsPerPacket() throws {
        let codec = PacketCodec(localPeerID: peer)
        let first = try codec.encode(.ping, PingPayload(nonce: 1, sentAtMilliseconds: 0))
        let second = try codec.encode(.ping, PingPayload(nonce: 2, sentAtMilliseconds: 0))
        XCTAssertEqual(second.header.sequence, first.header.sequence + 1)
    }

    func testChatIsClampedToProtocolLimit() {
        let long = String(repeating: "あ", count: 5000)
        let payload = ChatPayload(senderName: "spammer", text: long)
        XCTAssertEqual(payload.text.count, AbloxProtocol.maxChatLength)
    }

    func testSequenceRecencyHandlesWraparound() {
        XCTAssertTrue(isSequence(2, newerThan: 1))
        XCTAssertFalse(isSequence(1, newerThan: 2))
        XCTAssertFalse(isSequence(5, newerThan: 5))
        // The point of the half-space comparison: after wrapping, low numbers
        // are newer than high ones.
        XCTAssertTrue(isSequence(1, newerThan: UInt32.max))
        XCTAssertFalse(isSequence(UInt32.max, newerThan: 1))
    }

    // MARK: Reassembly

    private func bytes(for packets: [Packet]) -> Data {
        packets.reduce(into: Data()) { $0.append($1.header.encoded() + $1.payload) }
    }

    func testReassemblerHandlesExactlyOnePacket() throws {
        let codec = PacketCodec(localPeerID: peer)
        let packet = try codec.encode(.chat, ChatPayload(senderName: "a", text: "b"))
        var reassembler = StreamReassembler()
        let out = try reassembler.append(bytes(for: [packet]))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].payload, packet.payload)
        XCTAssertEqual(reassembler.bufferedByteCount, 0)
    }

    func testReassemblerHandlesSeveralPacketsInOneRead() throws {
        let codec = PacketCodec(localPeerID: peer)
        let packets = try (0..<5).map { i in
            try codec.encode(.chat, ChatPayload(senderName: "n\(i)", text: "msg \(i)"))
        }
        var reassembler = StreamReassembler()
        let out = try reassembler.append(bytes(for: packets))
        XCTAssertEqual(out.count, 5)
        for (sent, received) in zip(packets, out) {
            XCTAssertEqual(sent.payload, received.payload)
            XCTAssertEqual(sent.header.sequence, received.header.sequence)
        }
    }

    func testReassemblerHandlesHeaderSplitAcrossReads() throws {
        // The nasty case: TCP hands us 3 bytes, then the rest.
        let codec = PacketCodec(localPeerID: peer)
        let packet = try codec.encode(.chat, ChatPayload(senderName: "split", text: "across reads"))
        let all = bytes(for: [packet])

        var reassembler = StreamReassembler()
        XCTAssertTrue(try reassembler.append(all.prefix(3)).isEmpty)
        XCTAssertTrue(try reassembler.append(all.dropFirst(3).prefix(20)).isEmpty)
        let out = try reassembler.append(all.dropFirst(23))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].payload, packet.payload)
    }

    func testReassemblerDeliversByteByByte() throws {
        let codec = PacketCodec(localPeerID: peer)
        let packet = try codec.encode(.worldDelta, WorldDelta.remove(blockID: UUID()))
        let all = bytes(for: [packet])

        var reassembler = StreamReassembler()
        var delivered: [Packet] = []
        for byte in all {
            delivered += try reassembler.append(Data([byte]))
        }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].payload, packet.payload)
    }

    func testReassemblerKeepsPartialTailBuffered() throws {
        let codec = PacketCodec(localPeerID: peer)
        let a = try codec.encode(.chat, ChatPayload(senderName: "a", text: "first"))
        let b = try codec.encode(.chat, ChatPayload(senderName: "b", text: "second"))
        let all = bytes(for: [a, b])

        var reassembler = StreamReassembler()
        // Everything but the last 4 bytes of the second packet.
        let out = try reassembler.append(all.dropLast(4))
        XCTAssertEqual(out.count, 1, "only the first packet is complete")
        XCTAssertGreaterThan(reassembler.bufferedByteCount, 0)

        let rest = try reassembler.append(all.suffix(4))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].payload, b.payload)
        XCTAssertEqual(reassembler.bufferedByteCount, 0)
    }

    func testReassemblerRejectsOversizedPayload() {
        var header = PacketHeader(
            kind: .worldSnapshot,
            senderID: peer,
            sequence: 1,
            timestampMilliseconds: 0,
            payloadLength: 0
        )
        header.payloadLength = UInt32(AbloxProtocol.maxPayloadLength + 1)

        var reassembler = StreamReassembler()
        XCTAssertThrowsError(try reassembler.append(header.encoded())) { error in
            guard case let WireError.payloadTooLarge(length, limit) = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(length, AbloxProtocol.maxPayloadLength + 1)
            XCTAssertEqual(limit, AbloxProtocol.maxPayloadLength)
        }
    }

    func testReassemblerRejectsGarbageHeader() {
        var reassembler = StreamReassembler()
        let garbage = Data(repeating: 0xFF, count: PacketHeader.encodedSize)
        XCTAssertThrowsError(try reassembler.append(garbage)) { error in
            XCTAssertEqual(error as? WireError, .malformedHeader)
        }
    }

    func testEmptyPayloadPacketIsFramed() throws {
        let codec = PacketCodec(localPeerID: peer)
        let packet = codec.encodeEmpty(.leave)
        XCTAssertEqual(packet.header.payloadLength, 0)

        var reassembler = StreamReassembler()
        let out = try reassembler.append(packet.header.encoded())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .leave)
        XCTAssertTrue(out[0].payload.isEmpty)
    }

    func testEncodeToBytesMatchesHeaderPlusPayload() throws {
        let codec = PacketCodec(localPeerID: peer)
        let data = try codec.encodeToBytes(.ping, PingPayload(nonce: 7, sentAtMilliseconds: 99))
        var reassembler = StreamReassembler()
        let out = try reassembler.append(data)
        XCTAssertEqual(out.count, 1)
        let ping = try codec.decodePayload(PingPayload.self, from: out[0])
        XCTAssertEqual(ping.nonce, 7)
    }

    // MARK: Payload shapes

    func testWorldDeltaCodableRoundTrip() throws {
        let block = BlockData(name: "Test", shape: .sphere)
        let deltas: [WorldDelta] = [
            .insert(block),
            .update(block),
            .remove(blockID: block.id),
            .reparent(blockID: block.id, newParent: nil),
            .reparent(blockID: block.id, newParent: UUID()),
            .environment(.default),
            .rulesReplaced([EventRule(name: "r", trigger: .worldStart, actions: [.playSound(name: "x")])])
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for delta in deltas {
            let restored = try decoder.decode(WorldDelta.self, from: encoder.encode(delta))
            XCTAssertEqual(restored, delta, "\(delta)")
        }
    }

    func testEventTriggerAndActionUseReadableDiscriminators() throws {
        let encoder = JSONEncoder()
        let trigger = EventTrigger.proximity(blockID: UUID(), radius: 4)
        let json = String(decoding: try encoder.encode(trigger), as: UTF8.self)
        XCTAssertTrue(json.contains("\"proximity\""), json)
        XCTAssertTrue(json.contains("\"radius\""), json)

        let action = EventAction.awardPoints(25)
        let actionJSON = String(decoding: try encoder.encode(action), as: UTF8.self)
        XCTAssertTrue(actionJSON.contains("\"awardPoints\""), actionJSON)
    }

    func testEventTriggerRoundTripsEveryCase() throws {
        let id = UUID()
        let cases: [EventTrigger] = [
            .blockTouched(blockID: id),
            .tagTouched(tag: "coin"),
            .blockTapped(blockID: id),
            .proximity(blockID: id, radius: 2.5),
            .worldStart,
            .timer(interval: 3),
            .scoreReached(score: 100)
        ]
        for value in cases {
            let restored = try JSONDecoder().decode(EventTrigger.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(restored, value)
        }
    }

    func testEventActionRoundTripsEveryCase() throws {
        let id = UUID()
        let cases: [EventAction] = [
            .tint(blockID: id, color: .white, duration: 1),
            .move(blockID: id, offset: Vec3(1, 2, 3), duration: 0.5),
            .setVisible(blockID: id, visible: false),
            .setCollision(blockID: id, enabled: true),
            .teleportPlayer(to: Vec3(0, 5, 0)),
            .awardPoints(-3),
            .announce(message: "hi", duration: 2),
            .playSound(name: "ding"),
            .endRound(message: "done")
        ]
        for value in cases {
            let restored = try JSONDecoder().decode(EventAction.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(restored, value)
        }
    }

    func testProtocolConstantsAreStable() {
        // These are compatibility surface: changing one breaks older iPads,
        // so a deliberate test failure is the reminder to bump the version.
        XCTAssertEqual(AbloxProtocol.bonjourServiceType, "_ablox._tcp")
        XCTAssertEqual(AbloxProtocol.version, 3)
        XCTAssertEqual(PacketHeader.encodedSize, 33)
        XCTAssertEqual(PacketKind.handshake.rawValue, 1)
        XCTAssertEqual(PacketKind.leave.rawValue, 11)
        XCTAssertEqual(PacketKind.playerInput.rawValue, 12)
    }
}
