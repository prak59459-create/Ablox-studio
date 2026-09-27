import Foundation

/// A look as a short code to read out or type in, like "4K2P-9QXA-…":
/// colours, hat, face, pet and height, but never the name.
///
/// Wearing someone's code only puts on what this player owns. Anything
/// else is listed, so it can go on the wishlist, rather than being worn
/// for free.
public enum OutfitCode {

    /// What a code carries.
    public struct Outfit: Hashable, Sendable {
        public var body: ColorRGBA
        public var head: ColorRGBA
        public var accent: ColorRGBA
        public var hat: AvatarProfile.HatStyle
        public var face: AvatarProfile.Face
        public var pet: AvatarProfile.Pet
        public var hatColor: ColorRGBA?
        public var petColor: ColorRGBA
        public var height: Float
    }

    static let version: UInt8 = 1
    /// Crockford's base 32: no I, L, O or U, so nothing is misread.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func code(for profile: AvatarProfile) -> String {
        let span = heightRange.upperBound - heightRange.lowerBound
        let height = UInt8(Swift.max(0, Swift.min(255, ((profile.height - heightRange.lowerBound) / span * 255).rounded())))
        var bytes: [UInt8] = [
            version,
            paletteIndex(profile.bodyColor), paletteIndex(profile.headColor), paletteIndex(profile.accentColor),
            index(of: profile.hat), index(of: profile.face), index(of: profile.pet),
            profile.hatColor.map(paletteIndex) ?? 255, paletteIndex(profile.petColor),
            height
        ]
        bytes.append(checksum(bytes))
        let characters = base32(bytes)
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<Swift.min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// The outfit in a code, or nil for a mistyped or unknown one.
    public static func outfit(from text: String) -> Outfit? {
        var cleaned: [Character] = []
        for character in text.uppercased() {
            switch character {
            case "-", " ", "\n", "\t": continue
            case "O": cleaned.append("0")
            case "I", "L": cleaned.append("1")
            default: cleaned.append(character)
            }
        }
        guard let bytes = unbase32(cleaned), bytes.count == 11,
              bytes[0] == version, checksum(Array(bytes.dropLast())) == bytes[10] else { return nil }
        let palette = ColorRGBA.palette
        func colour(_ byte: UInt8) -> ColorRGBA? { Int(byte) < palette.count ? palette[Int(byte)] : nil }
        guard let body = colour(bytes[1]), let head = colour(bytes[2]), let accent = colour(bytes[3]),
              let hat = value(AvatarProfile.HatStyle.self, bytes[4]),
              let face = value(AvatarProfile.Face.self, bytes[5]),
              let pet = value(AvatarProfile.Pet.self, bytes[6]),
              let petColor = colour(bytes[8]) else { return nil }
        let span = heightRange.upperBound - heightRange.lowerBound
        return Outfit(body: body, head: head, accent: accent, hat: hat, face: face, pet: pet,
                      hatColor: colour(bytes[7]), petColor: petColor,
                      height: heightRange.lowerBound + Float(bytes[9]) / 255 * span)
    }

    /// `profile` wearing what it can of `outfit`, and the shop items it
    /// would need for the rest.
    public static func wear(_ outfit: Outfit, on profile: AvatarProfile, wallet: PlayerWallet) -> (profile: AvatarProfile, missing: [ShopItem]) {
        var look = profile
        var missing: [ShopItem] = []
        func take(_ kind: ShopItem.Kind, matching: (ShopItem) -> Bool, apply: (inout AvatarProfile) -> Void) {
            guard let item = ShopCatalogue.items(of: kind).first(where: matching) else { return }
            if wallet.owns(item) { apply(&look) } else { missing.append(item) }
        }
        take(.bodyColor, matching: { $0.color == outfit.body }) { $0.bodyColor = outfit.body }
        take(.headColor, matching: { $0.color == outfit.head }) { $0.headColor = outfit.head }
        take(.accentColor, matching: { $0.color == outfit.accent }) { $0.accentColor = outfit.accent }
        take(.hat, matching: { $0.hat == outfit.hat }) { $0.hat = outfit.hat }
        take(.face, matching: { $0.face == outfit.face }) { $0.face = outfit.face }
        take(.pet, matching: { $0.pet == outfit.pet }) { $0.pet = outfit.pet }
        // Colours of the hat and pet, and height, are free to choose anyway.
        look.hatColor = outfit.hatColor
        look.petColor = outfit.petColor
        look.height = Swift.max(heightRange.lowerBound, Swift.min(heightRange.upperBound, outfit.height))
        return (look, missing)
    }

    /// As the avatar screen's slider allows.
    public static let heightRange: ClosedRange<Float> = 0.8...1.25

    // MARK: Pieces

    static func paletteIndex(_ colour: ColorRGBA) -> UInt8 {
        let palette = ColorRGBA.palette
        if let exact = palette.firstIndex(of: colour) { return UInt8(exact) }
        // A colour from before the palette settled: the nearest one.
        func distance(_ other: ColorRGBA) -> Float {
            let r = other.r - colour.r, g = other.g - colour.g, b = other.b - colour.b
            return r * r + g * g + b * b
        }
        let nearest = palette.indices.min { distance(palette[$0]) < distance(palette[$1]) } ?? 0
        return UInt8(nearest)
    }

    static func index<T: CaseIterable & Equatable>(of value: T) -> UInt8 {
        UInt8(Array(T.allCases).firstIndex(of: value) ?? 0)
    }

    static func value<T: CaseIterable>(_ type: T.Type, _ byte: UInt8) -> T? {
        let all = Array(T.allCases)
        return Int(byte) < all.count ? all[Int(byte)] : nil
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var sum: UInt32 = 7
        for (index, byte) in bytes.enumerated() {
            sum = (sum &* 31 &+ UInt32(byte) &* UInt32(index + 1)) & 0xFFFF
        }
        return UInt8(sum & 0xFF) ^ UInt8(sum >> 8)
    }

    static func base32(_ bytes: [UInt8]) -> [Character] {
        var result: [Character] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { result.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return result
    }

    static func unbase32(_ characters: [Character]) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in characters {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return bytes
    }
}
