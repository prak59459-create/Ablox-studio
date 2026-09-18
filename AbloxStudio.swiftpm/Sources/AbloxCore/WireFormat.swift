import Foundation

// MARK: - Errors

public enum WireError: Error, LocalizedError, Sendable, Equatable {
    case malformedHeader
    case payloadTooLarge(length: Int, limit: Int)
    case unexpectedKind(expected: PacketKind, found: PacketKind)
    case protocolMismatch(local: Int, remote: Int)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .malformedHeader:
            return "Received a message Ablox could not read."
        case let .payloadTooLarge(length, limit):
            return "A peer sent an oversized message (\(length) bytes, limit \(limit))."
        case let .unexpectedKind(expected, found):
            return "Expected a \(expected) message but received \(found)."
        case let .protocolMismatch(local, remote):
            return "That iPad is running a different version of Ablox (protocol \(remote); this build speaks \(local)). Update both to play together."
        case let .decodingFailed(detail):
            return "Could not read message contents: \(detail)"
        }
    }
}

// MARK: - PacketCodec

/// Turns typed payloads into framed bytes and back.
///
/// Stateful only in `sequence`, which increments per encoded packet so a
/// receiver can drop stale `playerTransform` packets that arrive out of order.
public final class PacketCodec: @unchecked Sendable {
    public let localPeerID: PeerID

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var sequence: UInt32 = 0

    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private func nextSequence() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        // Wrap rather than trap. Sequence is only ever compared for recency,
        // and `isNewer(_:than:)` handles the wrap.
        sequence &+= 1
        return sequence
    }

    // MARK: Encoding

    /// Builds a packet from a `Codable` payload.
    public func encode<T: Encodable>(_ kind: PacketKind, _ payload: T, sender: PeerID? = nil) throws -> Packet {
        let body = try encoder.encode(payload)
        guard body.count <= AbloxProtocol.maxPayloadLength else {
            throw WireError.payloadTooLarge(length: body.count, limit: AbloxProtocol.maxPayloadLength)
        }
        let header = PacketHeader(
            kind: kind,
            senderID: sender ?? localPeerID,
            sequence: nextSequence(),
            timestampMilliseconds: PacketCodec.nowMilliseconds(),
            payloadLength: UInt32(body.count)
        )
        return Packet(header: header, payload: body)
    }

    /// A packet with no body — `leave` with no reason, for instance.
    public func encodeEmpty(_ kind: PacketKind, sender: PeerID? = nil) -> Packet {
        let header = PacketHeader(
            kind: kind,
            senderID: sender ?? localPeerID,
            sequence: nextSequence(),
            timestampMilliseconds: PacketCodec.nowMilliseconds(),
            payloadLength: 0
        )
        return Packet(header: header, payload: Data())
    }

    /// Header bytes followed by payload bytes: the complete on-wire form.
    /// Used directly by the datagram path and by tests; the
    /// `NWProtocolFramer` writes the two parts separately.
    public func encodeToBytes<T: Encodable>(_ kind: PacketKind, _ payload: T, sender: PeerID? = nil) throws -> Data {
        let packet = try encode(kind, payload, sender: sender)
        return packet.header.encoded() + packet.payload
    }

    // MARK: Decoding

    public func decodePayload<T: Decodable>(_ type: T.Type, from packet: Packet) throws -> T {
        do {
            return try decoder.decode(type, from: packet.payload)
        } catch {
            throw WireError.decodingFailed("\(type) — \(error.localizedDescription)")
        }
    }

    public static func nowMilliseconds() -> UInt64 {
        UInt64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - Sequence recency

/// Compares two wrapping sequence numbers. Treats the smaller half of the
/// 32-bit space as "ahead", so 1 is newer than 0xFFFFFFFF.
public func isSequence(_ candidate: UInt32, newerThan reference: UInt32) -> Bool {
    let half: UInt32 = 0x8000_0000
    return candidate != reference && (candidate &- reference) < half
}

// MARK: - StreamReassembler

/// Accumulates bytes from a stream and yields complete packets.
///
/// `AbloxFramer` (Network.framework) is the production path on Apple
/// platforms, but the exact same length-prefix logic lives here so it can be
/// exercised by unit tests on any platform — including the nasty cases:
/// a header split across two reads, several packets in one read, and a
/// truncated tail.
public struct StreamReassembler: Sendable {
    private var buffer = Data()
    public let payloadLimit: Int

    public init(payloadLimit: Int = AbloxProtocol.maxPayloadLength) {
        self.payloadLimit = payloadLimit
    }

    public var bufferedByteCount: Int { buffer.count }

    /// Feeds newly received bytes in and returns every packet that is now
    /// complete. Throws when a peer announces an implausible payload length,
    /// which the caller should treat as fatal for that connection.
    public mutating func append(_ incoming: Data) throws -> [Packet] {
        buffer.append(incoming)
        var packets: [Packet] = []

        while true {
            guard buffer.count >= PacketHeader.encodedSize else { break }

            // `buffer` is re-sliced below, so always index from startIndex
            // rather than assuming a zero-based offset.
            let headerData = buffer.prefix(PacketHeader.encodedSize)
            guard let header = PacketHeader(decoding: Data(headerData)) else {
                throw WireError.malformedHeader
            }

            let payloadLength = Int(header.payloadLength)
            guard payloadLength <= payloadLimit else {
                throw WireError.payloadTooLarge(length: payloadLength, limit: payloadLimit)
            }

            let total = PacketHeader.encodedSize + payloadLength
            guard buffer.count >= total else { break }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: PacketHeader.encodedSize)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: total)
            let payload = Data(buffer[payloadStart..<payloadEnd])

            packets.append(Packet(header: header, payload: payload))
            buffer = Data(buffer[payloadEnd...])
        }

        return packets
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
