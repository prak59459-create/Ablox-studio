import Foundation
#if canImport(Compression)
import Compression
#endif

// Reading a .zip — what GitHub hands out when you download a repository.
//
// The app downloads its own next version this way (see `AppUpdate`). Apple's
// frameworks have no zip reader on iPad, so this is one: the central
// directory, stored and deflated entries, and a CRC check on every file.
// It lives in the portable core so every path through it — including a
// hostile archive — is tested on Linux rather than on a child's iPad.

// MARK: - CRC-32

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - DEFLATE

/// Raw DEFLATE (RFC 1951) decoding: stored, fixed and dynamic blocks.
public enum Inflate {

    public enum Failure: Error, Equatable {
        case corrupt
        case tooLarge
    }

    /// - Parameters:
    ///   - expectedSize: how big the result should be, if known — room is
    ///     made up front, and on Apple platforms the system decoder is tried
    ///     first.
    ///   - limit: the most it may grow to. An archive can claim anything; a
    ///     "zip bomb" expands a few kilobytes into gigabytes.
    public static func decompress(_ input: [UInt8], expectedSize: Int? = nil, limit: Int) throws -> [UInt8] {
        #if canImport(Compression)
        if let size = expectedSize, size > 0, size <= limit, let fast = system(input, size: size) { return fast }
        #endif
        var decoder = Decoder(limit: limit)
        if let size = expectedSize, size <= limit { decoder.output.reserveCapacity(size) }
        try input.withUnsafeBufferPointer { try decoder.run($0) }
        return decoder.output
    }

    #if canImport(Compression)
    /// Apple's decoder, much faster than the one below. Only trusted when it
    /// produces exactly the size the archive said; the caller checks the CRC
    /// either way.
    private static func system(_ input: [UInt8], size: Int) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written = output.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { source in
                compression_decode_buffer(out.baseAddress!, size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? output : nil
    }
    #endif

    // Tables from RFC 1951, section 3.2.5.
    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                                            131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                              2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
                                               13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedLiterals: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return Huffman(lengths: lengths[...])!
    }()
    private static let fixedDistances = Huffman(lengths: [UInt8](repeating: 5, count: 30)[...])!

    /// A canonical Huffman code as one lookup table: the next `bits` bits of
    /// input (in the order DEFLATE packs them) index straight to the symbol
    /// and how many bits its code really used.
    struct Huffman {
        /// `symbol << 4 | length`; a length of 0 is a code nothing uses.
        let table: [UInt32]
        let bits: Int

        init?(lengths: ArraySlice<UInt8>) {
            let longest = Int(lengths.max() ?? 0)
            guard longest <= 15 else { return nil }
            bits = Swift.max(1, longest)
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { counts[Int(length)] += 1 }
            // Over-subscribed codes are invalid; incomplete ones are allowed
            // (a block with a single distance uses one).
            var left = 1
            for length in 1...15 {
                left = left * 2 - counts[length]
                if left < 0 { return nil }
            }
            // The first code of each length (RFC 1951, 3.2.2).
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1...15 {
                code = (code + counts[length - 1]) << 1
                next[length] = code
            }
            var table = [UInt32](repeating: 0, count: 1 << bits)
            for (offset, length) in lengths.enumerated() where length > 0 {
                let symbol = offset
                let size = Int(length)
                let assigned = next[size]
                next[size] += 1
                // DEFLATE sends a code's bits most significant first, but
                // reads everything else least significant first: reversed.
                var reversed = 0
                for bit in 0..<size where assigned & (1 << bit) != 0 { reversed |= 1 << (size - 1 - bit) }
                var index = reversed
                let entry = UInt32(symbol) << 4 | UInt32(size)
                while index < table.count {
                    table[index] = entry
                    index += 1 << size
                }
            }
            self.table = table
        }
    }

    private struct Decoder {
        let limit: Int
        var output: [UInt8] = []
        private var position = 0
        private var buffer: UInt64 = 0
        private var count = 0

        init(limit: Int) { self.limit = limit }

        mutating func run(_ input: UnsafeBufferPointer<UInt8>) throws {
            var last = false
            while !last {
                last = try take(1, input) == 1
                switch try take(2, input) {
                case 0: try stored(input)
                case 1: try codes(Inflate.fixedLiterals, Inflate.fixedDistances, input)
                case 2:
                    let (literals, distances) = try dynamicTables(input)
                    try codes(literals, distances, input)
                default: throw Failure.corrupt
                }
            }
        }

        // MARK: Bits

        private mutating func fill(_ input: UnsafeBufferPointer<UInt8>) {
            while count <= 56 {
                // Past the end reads as zeros; `consumed` catches a stream
                // that really needed them.
                let byte: UInt64 = position < input.count ? UInt64(input[position]) : 0
                position += 1
                buffer |= byte << UInt64(count)
                count += 8
            }
        }

        private func consumed(_ input: UnsafeBufferPointer<UInt8>) -> Bool {
            position * 8 - count <= input.count * 8
        }

        private mutating func take(_ n: Int, _ input: UnsafeBufferPointer<UInt8>) throws -> Int {
            if n == 0 { return 0 }
            if count < n { fill(input) }
            let value = Int(buffer & ((1 << UInt64(n)) - 1))
            buffer >>= UInt64(n)
            count -= n
            guard consumed(input) else { throw Failure.corrupt }
            return value
        }

        private mutating func decode(_ code: Huffman, _ input: UnsafeBufferPointer<UInt8>) throws -> Int {
            if count < code.bits { fill(input) }
            let entry = code.table[Int(buffer & ((1 << UInt64(code.bits)) - 1))]
            let length = Int(entry & 0xF)
            guard length > 0 else { throw Failure.corrupt }
            buffer >>= UInt64(length)
            count -= length
            guard consumed(input) else { throw Failure.corrupt }
            return Int(entry >> 4)
        }

        // MARK: Blocks

        private mutating func stored(_ input: UnsafeBufferPointer<UInt8>) throws {
            // To the next whole byte, then read straight from the input.
            let start = position - count / 8
            buffer = 0
            count = 0
            position = start
            guard position + 4 <= input.count else { throw Failure.corrupt }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let check = Int(input[position + 2]) | Int(input[position + 3]) << 8
            guard length == ~check & 0xFFFF else { throw Failure.corrupt }
            position += 4
            guard position + length <= input.count else { throw Failure.corrupt }
            guard output.count + length <= limit else { throw Failure.tooLarge }
            output.append(contentsOf: UnsafeBufferPointer(rebasing: input[position..<(position + length)]))
            position += length
        }

        private mutating func dynamicTables(_ input: UnsafeBufferPointer<UInt8>) throws -> (Huffman, Huffman) {
            let literalCount = try take(5, input) + 257
            let distanceCount = try take(5, input) + 1
            let lengthCount = try take(4, input) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure.corrupt }
            var codeLengths = [UInt8](repeating: 0, count: 19)
            for i in 0..<lengthCount { codeLengths[Inflate.codeLengthOrder[i]] = UInt8(try take(3, input)) }
            guard let lengthCode = Huffman(lengths: codeLengths[...]) else { throw Failure.corrupt }

            var lengths = [UInt8]()
            lengths.reserveCapacity(literalCount + distanceCount)
            while lengths.count < literalCount + distanceCount {
                let symbol = try decode(lengthCode, input)
                switch symbol {
                case 0...15:
                    lengths.append(UInt8(symbol))
                case 16:
                    guard let previous = lengths.last else { throw Failure.corrupt }
                    lengths.append(contentsOf: repeatElement(previous, count: 3 + (try take(2, input))))
                case 17:
                    lengths.append(contentsOf: repeatElement(0, count: 3 + (try take(3, input))))
                default:
                    lengths.append(contentsOf: repeatElement(0, count: 11 + (try take(7, input))))
                }
            }
            guard lengths.count == literalCount + distanceCount, lengths[256] > 0,
                  let literals = Huffman(lengths: lengths[0..<literalCount]),
                  let distances = Huffman(lengths: lengths[literalCount...]) else { throw Failure.corrupt }
            return (literals, distances)
        }

        private mutating func codes(_ literals: Huffman, _ distances: Huffman, _ input: UnsafeBufferPointer<UInt8>) throws {
            while true {
                let symbol = try decode(literals, input)
                if symbol < 256 {
                    guard output.count < limit else { throw Failure.tooLarge }
                    output.append(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                let lengthIndex = symbol - 257
                guard lengthIndex < Inflate.lengthBase.count else { throw Failure.corrupt }
                let length = Inflate.lengthBase[lengthIndex] + (try take(Inflate.lengthExtra[lengthIndex], input))
                let distanceIndex = try decode(distances, input)
                guard distanceIndex < Inflate.distanceBase.count else { throw Failure.corrupt }
                let distance = Inflate.distanceBase[distanceIndex] + (try take(Inflate.distanceExtra[distanceIndex], input))
                guard distance <= output.count else { throw Failure.corrupt }
                guard output.count + length <= limit else { throw Failure.tooLarge }
                // Byte by byte: a copy may overlap what it is writing
                // ("abcabcabc…" is distance 3, length 9).
                let start = output.count - distance
                for i in 0..<length { output.append(output[start + i]) }
            }
        }
    }
}

// MARK: - Zip

/// The entries of a .zip and their contents.
public struct ZipArchive {

    public enum Failure: Error, Equatable {
        case notAZip
        /// Archives over 4 GB, or with more than 65 535 entries. Nothing
        /// Ablox downloads is either.
        case zip64
        case unsupportedMethod(String)
        case corrupt(String)
        case checksum(String)
        case tooLarge(String)
    }

    public struct Entry: Equatable {
        public let name: String
        let method: Int
        let crc: UInt32
        let compressedSize: Int
        public let size: Int
        let localHeader: Int
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public let entries: [Entry]
    private let bytes: [UInt8]

    public init(_ data: Data) throws {
        try self.init([UInt8](data))
    }

    public init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        // The end record is in the last 22 bytes plus up to 64 KB of comment.
        guard bytes.count >= 22 else { throw Failure.notAZip }
        var end = -1
        var at = bytes.count - 22
        let floor = Swift.max(0, bytes.count - 22 - 65_535)
        while at >= floor {
            if Self.u32(bytes, at) == 0x0605_4B50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw Failure.notAZip }
        let count = Self.u16(bytes, end + 10)
        let directorySize = Self.u32(bytes, end + 12)
        let directoryStart = Self.u32(bytes, end + 16)
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryStart != 0xFFFF_FFFF else { throw Failure.zip64 }
        guard directoryStart + directorySize <= end else { throw Failure.corrupt("central directory") }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var cursor = directoryStart
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, Self.u32(bytes, cursor) == 0x0201_4B50 else { throw Failure.corrupt("central directory") }
            let method = Self.u16(bytes, cursor + 10)
            let crc = UInt32(Self.u32(bytes, cursor + 16))
            let compressed = Self.u32(bytes, cursor + 20)
            let size = Self.u32(bytes, cursor + 24)
            let nameLength = Self.u16(bytes, cursor + 28)
            let extraLength = Self.u16(bytes, cursor + 30)
            let commentLength = Self.u16(bytes, cursor + 32)
            let local = Self.u32(bytes, cursor + 42)
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, local != 0xFFFF_FFFF else { throw Failure.zip64 }
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw Failure.corrupt("central directory") }
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            // Flag bit 11 says UTF-8; older tools wrote code page 437, which
            // agrees with it for the plain names anything here uses.
            let name = String(decoding: nameBytes, as: UTF8.self)
            entries.append(Entry(name: name, method: method, crc: crc, compressedSize: compressed, size: size, localHeader: local))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// An entry's bytes, checked against its CRC.
    public func contents(of entry: Entry, limit: Int = 64 * 1024 * 1024) throws -> [UInt8] {
        guard entry.size <= limit else { throw Failure.tooLarge(entry.name) }
        let header = entry.localHeader
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4B50 else { throw Failure.corrupt(entry.name) }
        let start = header + 30 + Self.u16(bytes, header + 26) + Self.u16(bytes, header + 28)
        guard start + entry.compressedSize <= bytes.count else { throw Failure.corrupt(entry.name) }
        let raw = Array(bytes[start..<(start + entry.compressedSize)])
        let result: [UInt8]
        switch entry.method {
        case 0:
            result = raw
        case 8:
            do {
                result = try Inflate.decompress(raw, expectedSize: entry.size, limit: Swift.min(limit, entry.size))
            } catch Inflate.Failure.tooLarge {
                throw Failure.tooLarge(entry.name)
            } catch {
                throw Failure.corrupt(entry.name)
            }
        default:
            throw Failure.unsupportedMethod(entry.name)
        }
        guard result.count == entry.size else { throw Failure.corrupt(entry.name) }
        guard CRC32.checksum(result) == entry.crc else { throw Failure.checksum(entry.name) }
        return result
    }

    /// The path to write an entry at, or nil for one that would land outside
    /// the folder it is unpacked into: `../`, an absolute path, a drive
    /// letter, a backslash, or nothing at all.
    public static func safePath(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.contains(":") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        for (i, part) in parts.enumerated() {
            if part.isEmpty {
                // Only a trailing slash (a folder) may leave an empty part.
                guard i == parts.count - 1 else { return nil }
                continue
            }
            guard part != "..", part != "." else { return nil }
            kept.append(part)
        }
        return kept.isEmpty ? nil : kept.joined(separator: "/")
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 2 <= b.count else { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }
}
