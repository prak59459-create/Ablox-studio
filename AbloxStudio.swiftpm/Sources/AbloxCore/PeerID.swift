import Foundation

// A player's identity, in a file of its own. Most of the app uses it, so
// anything else declared beside it — the movement rules, still in
// Player.swift — would rebuild all of that after an update that touched it.

/// Stable identity for one device in a session.
///
/// A thin wrapper over `UUID` rather than a bare `UUID` so that a peer id can
/// never be silently confused with a block id — both are UUIDs, and they show
/// up side by side in packet payloads.
public struct PeerID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    /// The 16 raw bytes, as they appear in a packet header.
    public var bytes: [UInt8] {
        let u = raw.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// Rebuilds a peer id from exactly 16 bytes. Returns nil otherwise.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        raw = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public var description: String { String(raw.uuidString.prefix(8)) }

    /// FNV-1a over all sixteen id bytes, salted with `seed`.
    ///
    /// Stable across processes, platforms and launches — unlike `hashValue`,
    /// which Swift seeds randomly per process. Used wherever a peer id needs
    /// to pick deterministically from a list (avatar looks, colour slots) and
    /// every device must reach the same answer.
    public func stableHash(seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 &+ seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Sentinel used by the host when a message is server-authored rather
    /// than relayed from a player.
    public static let host = PeerID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
}
