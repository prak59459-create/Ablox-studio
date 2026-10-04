import Foundation

// How a player's name and chat look over their head: the card behind the
// name and the bubble round what they say. Chosen on the avatar screen,
// bought in the shop, and seen by everyone in the room.

/// The colours of a card: its fill, its text, and an edge if it has one.
public struct CardColours: Hashable, Sendable {
    public var background: ColorRGBA
    public var text: ColorRGBA
    public var border: ColorRGBA?
    /// The title under a name.
    public var accent: ColorRGBA

    public init(background: ColorRGBA, text: ColorRGBA, border: ColorRGBA? = nil, accent: ColorRGBA) {
        self.background = background
        self.text = text
        self.border = border
        self.accent = accent
    }

    static func hex(_ value: String) -> ColorRGBA { ColorRGBA(hex: value) ?? ColorRGBA(r: 1, g: 1, b: 1) }
}

extension AvatarProfile {

    /// The card behind a name.
    public enum NamePlate: String, Codable, CaseIterable, Sendable {
        case classic, sky, candy, mint, sunset, gold, neon, midnight, ice, lava, royal

        public var displayName: String {
            switch self {
            case .classic: return L("Classic")
            case .sky: return L("Sky name")
            case .candy: return L("Candy name")
            case .mint: return L("Mint name")
            case .sunset: return L("Sunset name")
            case .gold: return L("Gold name")
            case .neon: return L("Neon name")
            case .midnight: return L("Midnight name")
            case .ice: return L("Ice name")
            case .lava: return L("Lava name")
            case .royal: return L("Royal name")
            }
        }

        public var englishName: String {
            self == .classic ? "Classic" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() + " name"
        }

        public var colours: CardColours {
            let white = CardColours.hex("#FFFFFF")
            switch self {
            case .classic:
                return CardColours(background: ColorRGBA(r: 0, g: 0, b: 0, a: 0.42), text: white, accent: CardColours.hex("#FFD64D"))
            case .sky:
                return CardColours(background: CardColours.hex("#0EA5E9").withAlpha(0.85), text: white, accent: CardColours.hex("#E0F2FE"))
            case .candy:
                return CardColours(background: CardColours.hex("#F9A8D4").withAlpha(0.92), text: CardColours.hex("#831843"),
                                   border: white, accent: CardColours.hex("#9D174D"))
            case .mint:
                return CardColours(background: CardColours.hex("#6EE7B7").withAlpha(0.9), text: CardColours.hex("#064E3B"),
                                   accent: CardColours.hex("#065F46"))
            case .sunset:
                return CardColours(background: CardColours.hex("#F97316").withAlpha(0.88), text: white,
                                   border: CardColours.hex("#FDE047"), accent: CardColours.hex("#FEF08A"))
            case .gold:
                return CardColours(background: CardColours.hex("#422006").withAlpha(0.85), text: CardColours.hex("#FACC15"),
                                   border: CardColours.hex("#FACC15"), accent: CardColours.hex("#FDE68A"))
            case .neon:
                return CardColours(background: ColorRGBA(r: 0.02, g: 0.02, b: 0.08, a: 0.8), text: CardColours.hex("#22D3EE"),
                                   border: CardColours.hex("#E879F9"), accent: CardColours.hex("#E879F9"))
            case .midnight:
                return CardColours(background: CardColours.hex("#1E1B4B").withAlpha(0.9), text: CardColours.hex("#C7D2FE"),
                                   accent: CardColours.hex("#A5B4FC"))
            case .ice:
                return CardColours(background: CardColours.hex("#E0F2FE").withAlpha(0.9), text: CardColours.hex("#075985"),
                                   border: CardColours.hex("#7DD3FC"), accent: CardColours.hex("#0369A1"))
            case .lava:
                return CardColours(background: CardColours.hex("#7F1D1D").withAlpha(0.9), text: CardColours.hex("#FDBA74"),
                                   border: CardColours.hex("#EF4444"), accent: CardColours.hex("#FCA5A5"))
            case .royal:
                return CardColours(background: CardColours.hex("#581C87").withAlpha(0.9), text: white,
                                   border: CardColours.hex("#FACC15"), accent: CardColours.hex("#FACC15"))
            }
        }

        public var price: Int {
            switch self {
            case .classic: return 0
            case .sky, .candy, .mint: return 120
            case .sunset, .ice, .midnight: return 180
            case .neon, .lava: return 250
            case .gold, .royal: return 400
            }
        }
    }

    /// The bubble round what someone says.
    public enum BubbleStyle: String, Codable, CaseIterable, Sendable {
        case classic, night, candy, sky, mint, sun, comic, lava, grape, cloud, gold

        public var displayName: String {
            switch self {
            case .classic: return L("Classic")
            case .night: return L("Night bubble")
            case .candy: return L("Candy bubble")
            case .sky: return L("Sky bubble")
            case .mint: return L("Mint bubble")
            case .sun: return L("Sun bubble")
            case .comic: return L("Comic bubble")
            case .lava: return L("Lava bubble")
            case .grape: return L("Grape bubble")
            case .cloud: return L("Cloud bubble")
            case .gold: return L("Gold bubble")
            }
        }

        public var englishName: String {
            self == .classic ? "Classic" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() + " bubble"
        }

        public var colours: CardColours {
            let dark = CardColours.hex("#1C1F26")
            let white = CardColours.hex("#FFFFFF")
            switch self {
            case .classic: return CardColours(background: white, text: dark, accent: dark)
            case .night: return CardColours(background: CardColours.hex("#1F2937"), text: CardColours.hex("#F9FAFB"), accent: white)
            case .candy: return CardColours(background: CardColours.hex("#FBCFE8"), text: CardColours.hex("#831843"), accent: dark)
            case .sky: return CardColours(background: CardColours.hex("#BAE6FD"), text: CardColours.hex("#0C4A6E"), accent: dark)
            case .mint: return CardColours(background: CardColours.hex("#BBF7D0"), text: CardColours.hex("#14532D"), accent: dark)
            case .sun: return CardColours(background: CardColours.hex("#FEF08A"), text: CardColours.hex("#713F12"), accent: dark)
            case .comic: return CardColours(background: white, text: dark, border: dark, accent: dark)
            case .lava: return CardColours(background: CardColours.hex("#EA580C"), text: white, accent: white)
            case .grape: return CardColours(background: CardColours.hex("#7E22CE"), text: white, accent: white)
            case .cloud: return CardColours(background: CardColours.hex("#F1F5F9"), text: CardColours.hex("#334155"),
                                            border: CardColours.hex("#93C5FD"), accent: dark)
            case .gold: return CardColours(background: CardColours.hex("#FDE68A"), text: CardColours.hex("#78350F"),
                                           border: CardColours.hex("#D97706"), accent: dark)
            }
        }

        public var price: Int {
            switch self {
            case .classic: return 0
            case .sky, .mint, .sun, .cloud: return 100
            case .candy, .night, .comic: return 150
            case .lava, .grape: return 200
            case .gold: return 350
            }
        }
    }
}

// MARK: - Profiles: safe to send, and without an item
//
// What the app adds to a profile is here, beside the type, not in the files
// that use it: an extension of a type this many files use makes its file a
// dependency of all of them, so changing a feature file would rebuild them
// all (AbloxCore/Comparisons.swift says why).
public extension AvatarProfile {
    static let maximumNameLength = 24
    /// What a player may choose for themselves. A script can still make
    /// someone a giant with `p.size`; the host decides that, not the guest.
    static let chosenHeightRange: ClosedRange<Float> = 0.5...1.6

    /// The profile as a guest sent it, made safe to show everyone: a short
    /// single-line name, a sensible size, real colours.
    func sanitizedForNetwork() -> AvatarProfile {
        var copy = self
        let cleaned = displayName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayName = ChatModerator().cleanName(String(name.prefix(Self.maximumNameLength)))
        if copy.displayName.isEmpty { copy.displayName = "Player" }
        let title = String(String.UnicodeScalarView(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = ChatModerator().cleanName(String(title.prefix(Self.maximumNameLength)))
        if copy.title == "Player" { copy.title = "" }
        copy.height = height.isFinite ? Swift.min(Swift.max(height, Self.chosenHeightRange.lowerBound), Self.chosenHeightRange.upperBound) : 1
        copy.bodyColor = bodyColor.clamped
        copy.headColor = headColor.clamped
        copy.accentColor = accentColor.clamped
        copy.rideColor = rideColor.clamped
        return copy
    }
}

public extension AvatarProfile {
    /// This look without `item` — each slot it filled back to a free choice —
    /// for when a purchase is undone.
    func removing(_ item: ShopItem) -> AvatarProfile {
        var look = self
        func free(_ kind: ShopItem.Kind) -> ShopItem? { ShopCatalogue.items(of: kind).first(where: \.isFree) }
        switch item.kind {
        case .bodyColor: if look.bodyColor == item.color, let c = free(.bodyColor)?.color { look.bodyColor = c }
        case .headColor: if look.headColor == item.color, let c = free(.headColor)?.color { look.headColor = c }
        case .accentColor: if look.accentColor == item.color, let c = free(.accentColor)?.color { look.accentColor = c }
        case .hat: if look.hat == item.hat { look.hat = .none }
        case .face: if look.face == item.face, let f = free(.face)?.face { look.face = f }
        case .pet: if look.pet == item.pet { look.pet = .none }
        case .trail: if look.trail == item.trail { look.trail = .none }
        case .aura: if look.aura == item.aura { look.aura = .none }
        case .nameplate: if look.nameplate == item.nameplate { look.nameplate = .classic }
        case .bubble: if look.bubble == item.bubble { look.bubble = .classic }
        }
        return look
    }
}
