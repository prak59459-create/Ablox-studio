import Foundation

/// A seal on the files Ablox hands out — a backup, one game's save — so a
/// file changed by hand (more coins, every hat) is noticed when it is read
/// back.
///
/// The seal is an HMAC-SHA256 of the file's JSON with the `seal` key taken
/// out, written back into the same JSON object as `"seal"`. Older versions of
/// Ablox ignore the extra key, so a sealed file still opens on an iPad that
/// has not updated.
///
/// The key ships inside the app, so this stops editing a file in a text
/// editor, not someone who reads Ablox's source; it is a lock on the toy box,
/// not a bank vault. Coins never leave the iPad any other way.
public enum FileSeal {

    static let key = Array("Ablox file seal · v1 · wallets are earned in games".utf8)
    static let field = "seal"

    /// The same JSON object with a `seal` key added (or replaced).
    public static func sealed(_ json: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object[field] = nil
        object[field] = try code(for: object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Whether the file carries a seal that matches its contents. False for
    /// a file with no seal (made before seals, or with it deleted) and for
    /// anything that is not a JSON object.
    public static func isIntact(_ data: Data) -> Bool {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let seal = object[field] as? String else { return false }
        object[field] = nil
        guard let expected = try? code(for: object) else { return false }
        return constantTimeEqual(Array(seal.utf8), Array(expected.utf8))
    }

    /// The sealed bytes are the object re-written with sorted keys, so the
    /// writer and the reader hash exactly the same text whatever order the
    /// file's keys or a set's members came in.
    private static func code(for object: [String: Any]) throws -> String {
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return hex(SHA256Digest.hmac(key: key, message: Array(canonical)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return text
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// SHA-256 and HMAC-SHA256 (FIPS 180-4, RFC 2104), written out so AbloxCore
/// stays Foundation-only and testable off the iPad.
enum SHA256Digest {

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(padded[j]) << 24 | UInt32(padded[j + 1]) << 16 | UInt32(padded[j + 2]) << 8 | UInt32(padded[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ choose &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in h {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var block = key.count > 64 ? hash(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = hash(block.map { $0 ^ 0x36 } + message)
        return hash(block.map { $0 ^ 0x5c } + inner)
    }

    private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
