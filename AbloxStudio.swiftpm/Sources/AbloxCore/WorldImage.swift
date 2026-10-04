import Foundation

// Pictures on blocks, in a file of its own, split from WorldFeatures.swift:
// a change here rebuilds only the files that use what is here, not every
// file that uses anything that was declared beside it.

/// A picture kept in the world file, shown on blocks that name it.
public struct WorldImage: Codable, Hashable, Sendable, Identifiable {
    /// Twelve of a quarter of a megabyte: with the blocks, still well inside
    /// one packet (`AbloxProtocol.maxPayloadLength`) when the world is sent.
    public static let maximumCount = 12
    public static let maximumBytes = 250_000

    public var id: UUID
    public var name: String
    /// PNG or JPEG.
    public var data: Data

    public init(id: UUID = UUID(), name: String, data: Data) {
        self.id = id
        self.name = String(name.prefix(60))
        self.data = data
    }

    /// Small enough to send to everyone, and looks like a picture.
    public var isAcceptable: Bool {
        guard data.count <= Self.maximumBytes, data.count > 8 else { return false }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let head = [UInt8](data.prefix(4))
        return head.starts(with: png) || head.starts(with: jpeg)
    }
}
