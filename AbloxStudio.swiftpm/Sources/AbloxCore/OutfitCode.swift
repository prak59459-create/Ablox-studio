import Foundation

/// A look as a short code to read out or type in, like "4K2P-9QXA-…":
/// colours, hat, face, pet and height — and trail, aura, name card and
/// bubble when any is chosen — but never the name.
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
        /// Only in the longer codes; nil keeps what the wearer has on.
        public var trail: AvatarProfile.Trail?
        public var aura: AvatarProfile.Aura?
        public var nameplate: AvatarProfile.NamePlate?
        public var bubble: AvatarProfile.BubbleStyle?
    }

    static let version: UInt8 = 1
    /// A look with a trail, aura, name card or bubble. Plain looks keep the
    /// first kind of code, so an older iPad can still read them.
    static let versionWithExtras: UInt8 = 2
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
        if profile.trail != .none || profile.aura != .none || profile.nameplate != .classic || profile.bubble != .classic {
            bytes[0] = versionWithExtras
            bytes += [index(of: profile.trail), index(of: profile.aura), index(of: profile.nameplate), index(of: profile.bubble)]
        }
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
        guard let bytes = unbase32(cleaned), let kind = bytes.first,
              (kind == version && bytes.count == 11) || (kind == versionWithExtras && bytes.count == 15),
              checksum(Array(bytes.dropLast())) == bytes[bytes.count - 1] else { return nil }
        let palette = ColorRGBA.palette
        func colour(_ byte: UInt8) -> ColorRGBA? { Int(byte) < palette.count ? palette[Int(byte)] : nil }
        guard let body = colour(bytes[1]), let head = colour(bytes[2]), let accent = colour(bytes[3]),
              let hat = value(AvatarProfile.HatStyle.self, bytes[4]),
              let face = value(AvatarProfile.Face.self, bytes[5]),
              let pet = value(AvatarProfile.Pet.self, bytes[6]),
              let petColor = colour(bytes[8]) else { return nil }
        let span = heightRange.upperBound - heightRange.lowerBound
        var outfit = Outfit(body: body, head: head, accent: accent, hat: hat, face: face, pet: pet,
                            hatColor: colour(bytes[7]), petColor: petColor,
                            height: heightRange.lowerBound + Float(bytes[9]) / 255 * span)
        if kind == versionWithExtras {
            // Something from a newer iPad that this one lacks is left off.
            outfit.trail = value(AvatarProfile.Trail.self, bytes[10]) ?? AvatarProfile.Trail.none
            outfit.aura = value(AvatarProfile.Aura.self, bytes[11]) ?? AvatarProfile.Aura.none
            outfit.nameplate = value(AvatarProfile.NamePlate.self, bytes[12]) ?? .classic
            outfit.bubble = value(AvatarProfile.BubbleStyle.self, bytes[13]) ?? .classic
        }
        return outfit
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
        if let trail = outfit.trail { take(.trail, matching: { $0.trail == trail }) { $0.trail = trail } }
        if let aura = outfit.aura { take(.aura, matching: { $0.aura == aura }) { $0.aura = aura } }
        if let plate = outfit.nameplate { take(.nameplate, matching: { $0.nameplate == plate }) { $0.nameplate = plate } }
        if let bubble = outfit.bubble { take(.bubble, matching: { $0.bubble == bubble }) { $0.bubble = bubble } }
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
