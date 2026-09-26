import Foundation

// MARK: - Shop catalogue

/// Something a player can unlock with coins.
///
/// Items only ever change how an avatar *looks*. Nothing in the shop affects
/// movement, reach or score, because a local multiplayer game where the
/// richest player is also the fastest is a game children stop playing
/// together.
public struct ShopItem: Codable, Hashable, Identifiable, Sendable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case bodyColor
        case headColor
        case accentColor
        case hat
        case face
        case pet

        public var displayName: String {
            switch self {
            case .bodyColor: return L("Body")
            case .headColor: return L("Head & arms")
            case .accentColor: return L("Legs & hat")
            case .hat: return L("Hat")
            case .face: return L("Face")
            case .pet: return L("Pet")
            }
        }
    }

    /// Stable identifier, used as the inventory key. A string rather than a
    /// UUID so a saved wallet stays readable and a catalogue entry can be
    /// re-added later without orphaning what people already bought.
    public let id: String
    /// The English name. Built once into the catalogue, so it is stored as the
    /// original and translated when shown — `displayName`. Translating it here
    /// would freeze whatever language the app happened to be in when the
    /// catalogue was first built.
    public let name: String

    /// The name to show. Falls back to `name` for anything untranslated, so a
    /// new colour is readable the moment it exists.
    public var displayName: String { L(name) }
    public let kind: Kind
    public let price: Int
    /// For colour items.
    public let color: ColorRGBA?
    /// For hat items.
    public let hat: AvatarProfile.HatStyle?
    /// For face items.
    public let face: AvatarProfile.Face?
    /// For pet items.
    public let pet: AvatarProfile.Pet?

    public var rarity: ItemRarity { ItemRarity(price: price) }

    public init(
        id: String,
        name: String,
        kind: Kind,
        price: Int,
        color: ColorRGBA? = nil,
        hat: AvatarProfile.HatStyle? = nil,
        face: AvatarProfile.Face? = nil,
        pet: AvatarProfile.Pet? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.price = price
        self.color = color
        self.hat = hat
        self.face = face
        self.pet = pet
    }

    /// Items priced 0 are owned from the start and never appear as locked.
    public var isFree: Bool { price <= 0 }
}

/// Everything purchasable, and what a new player already owns.
public enum ShopCatalogue {

    /// Named so the ids read in a saved file: `color.cyan`, `hat.crown`.
    public static let items: [ShopItem] = {
        var result: [ShopItem] = []

        // The first four colours of the palette are free, so a brand-new
        // player can still make an avatar that looks like theirs before they
        // have earned a single coin.
        let colourNames = [
            "coral", "amber", "sun", "mint", "cyan", "blue",
            "violet", "pink", "chalk", "concrete", "slate", "graphite"
        ]
        for (index, colour) in ColorRGBA.palette.enumerated() {
            let name = index < colourNames.count ? colourNames[index] : "colour\(index)"
            // Priced by scarcity, not by quality — later palette entries cost
            // more simply to give the earning loop somewhere to go.
            let price = index < 4 ? 0 : 20 + (index - 4) * 15
            for kind in [ShopItem.Kind.bodyColor, .headColor, .accentColor] {
                result.append(ShopItem(
                    id: "\(kind.rawValue).\(name)",
                    name: name.capitalized,
                    kind: kind,
                    price: price,
                    color: colour
                ))
            }
        }

        for hat in AvatarProfile.HatStyle.allCases {
            result.append(ShopItem(
                id: "hat.\(hat.rawValue)",
                name: hat.displayName,
                kind: .hat,
                price: hat == .none ? 0 : 75,
                hat: hat
            ))
        }

        let facePrices: [AvatarProfile.Face: Int] = [.smile: 0, .grin: 0, .wink: 30, .surprised: 40, .sleepy: 40, .cool: 80,
                                                     .cat: 120, .robot: 120, .heart: 160]
        for face in AvatarProfile.Face.allCases {
            let faceNames: [AvatarProfile.Face: String] = [.smile: "Smile", .grin: "Grin", .wink: "Wink", .cool: "Sunglasses",
                                                           .surprised: "Surprised", .sleepy: "Sleepy", .cat: "Cat", .robot: "Robot",
                                                           .heart: "Heart eyes"]
            result.append(ShopItem(id: "face.\(face.rawValue)", name: faceNames[face] ?? face.rawValue, kind: .face,
                                   price: facePrices[face] ?? 50, face: face))
        }
        let petPrices: [AvatarProfile.Pet: Int] = [.none: 0, .cat: 150, .dog: 150, .bunny: 200, .bird: 250, .slime: 300,
                                                   .robot: 400, .dragon: 600]
        for pet in AvatarProfile.Pet.allCases {
            result.append(ShopItem(id: "pet.\(pet.rawValue)", name: pet.rawValue.capitalized, kind: .pet,
                                   price: petPrices[pet] ?? 200, pet: pet))
        }

        return result
    }()

    public static func item(id: String) -> ShopItem? {
        items.first { $0.id == id }
    }

    public static func items(of kind: ShopItem.Kind) -> [ShopItem] {
        items.filter { $0.kind == kind }
    }

    /// Ids owned without buying anything.
    public static var freeItemIDs: Set<String> {
        Set(items.filter(\.isFree).map(\.id))
    }
}

// MARK: - Wallet

/// A player's coins and what they own.
///
/// Local and per-device. There is no server to hold a balance, and the
/// alternative — trusting a peer's claim about its own coins — would make the
/// first child who reads the protocol very rich. Coins are earned from the
/// host's authoritative score (see `EventMachine`), and spent here.
public struct PlayerWallet: Codable, Hashable, Sendable {

    public private(set) var coins: Int
    public private(set) var ownedItemIDs: Set<String>
    /// Lifetime total, which never goes down. Shown as a career stat, and
    /// keeps "you have earned 500 coins" honest after spending.
    public private(set) var lifetimeEarned: Int

    public init(coins: Int = 0, ownedItemIDs: Set<String> = [], lifetimeEarned: Int = 0) {
        self.coins = coins
        // Free items are always owned, including ones added by a later
        // version — recomputed on load rather than stored, so the catalogue
        // stays the single source of truth.
        self.ownedItemIDs = ownedItemIDs.union(ShopCatalogue.freeItemIDs)
        self.lifetimeEarned = Swift.max(lifetimeEarned, coins)
    }

    public enum PurchaseResult: Equatable, Sendable {
        case purchased(ShopItem)
        case alreadyOwned
        case notEnoughCoins(shortfall: Int)
        case unknownItem

        public var succeeded: Bool {
            if case .purchased = self { return true }
            return false
        }

        public var message: String {
            switch self {
            case let .purchased(item): return "Unlocked \(item.name)"
            case .alreadyOwned: return "You already have this"
            case let .notEnoughCoins(shortfall): return "You need \(shortfall) more coin\(shortfall == 1 ? "" : "s")"
            case .unknownItem: return "That item is no longer available"
            }
        }
    }

    public func owns(_ itemID: String) -> Bool {
        ownedItemIDs.contains(itemID)
    }

    public func owns(_ item: ShopItem) -> Bool {
        owns(item.id)
    }

    public func canAfford(_ item: ShopItem) -> Bool {
        coins >= item.price
    }

    /// Credits coins earned in a round.
    ///
    /// Negative and zero amounts are ignored rather than allowed to debit:
    /// earning is the only way in, and a hazard that costs score must not also
    /// take coins somebody already banked.
    public mutating func earn(_ amount: Int) {
        guard amount > 0 else { return }
        coins += amount
        lifetimeEarned += amount
    }

    @discardableResult
    public mutating func purchase(_ itemID: String) -> PurchaseResult {
        guard let item = ShopCatalogue.item(id: itemID) else { return .unknownItem }
        guard !owns(item) else { return .alreadyOwned }
        guard canAfford(item) else { return .notEnoughCoins(shortfall: item.price - coins) }

        coins -= item.price
        ownedItemIDs.insert(item.id)
        return .purchased(item)
    }

    /// Everything owned of a given kind, in catalogue order.
    public func ownedItems(of kind: ShopItem.Kind) -> [ShopItem] {
        ShopCatalogue.items(of: kind).filter { owns($0) }
    }

    /// Still-locked items of a kind, cheapest first — the order the shop
    /// shows them, so the next affordable thing is always at the top.
    public func lockedItems(of kind: ShopItem.Kind) -> [ShopItem] {
        ShopCatalogue.items(of: kind)
            .filter { !owns($0) }
            .sorted { $0.price < $1.price }
    }

    /// Decoded explicitly rather than by synthesis.
    ///
    /// The synthesized decoder assigns stored properties directly, so it would
    /// skip the free-item grant in `init(coins:ownedItemIDs:lifetimeEarned:)`
    /// — and a wallet saved before a free item existed would show that item
    /// locked forever. Routing through the designated initialiser keeps the
    /// catalogue the single source of truth for what is free.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            coins: try c.decodeIfPresent(Int.self, forKey: .coins) ?? 0,
            ownedItemIDs: try c.decodeIfPresent(Set<String>.self, forKey: .ownedItemIDs) ?? [],
            lifetimeEarned: try c.decodeIfPresent(Int.self, forKey: .lifetimeEarned) ?? 0
        )
    }

    /// Resets coins and purchases. Exposed for a "start over" control.
    public mutating func reset() {
        coins = 0
        ownedItemIDs = ShopCatalogue.freeItemIDs
        lifetimeEarned = 0
    }
}

// MARK: - Earning

/// Converts a round's score into coins.
///
/// Separate from `PlayerWallet` so the rate is one documented place rather
/// than a multiplier buried in a view, and so it can be tuned without
/// touching persistence.
public enum CoinRate {
    /// Coins per point of score. One-to-one: an exchange rate that needs
    /// explaining is an exchange rate children will assume is cheating them.
    public static let perScorePoint = 1

    /// Awarded for finishing a round at a goal block, on top of score. Enough
    /// to be worth reaching the end for, not enough to make score pointless.
    public static let roundCompletionBonus = 25

    /// Coins for a score, floored at zero — a negative round earns nothing
    /// rather than costing previously banked coins.
    public static func coins(forScore score: Int, completedRound: Bool = false) -> Int {
        let earned = Swift.max(0, score) * perScorePoint
        return earned + (completedRound ? roundCompletionBonus : 0)
    }
}
