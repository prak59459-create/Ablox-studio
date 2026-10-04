import Foundation

// The app's version number, in a file of its own: it writes its own `<` and
// `==`, and an operator written for a type makes every file that compares
// anything depend on the file that type is in (AbloxCore/Comparisons.swift
// says why). Here it shares that file with nothing that changes.

/// "1.2.3": a version people read, compared number by number.
public struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy(\.isASCII), let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// 1.2 and 1.2.0 are the same version.
    private var padded: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.padded.lexicographicallyPrecedes(rhs.padded)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.padded == rhs.padded }
    public func hash(into hasher: inout Hasher) { hasher.combine(padded) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
