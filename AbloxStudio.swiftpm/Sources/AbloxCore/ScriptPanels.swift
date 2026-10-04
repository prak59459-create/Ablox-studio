import Foundation

// The way, a player's things, conversations, shops, time and rankings, in a
// file of its own, split from WorldFeatures.swift: a change here rebuilds
// only the files that use what is here, not every file that uses anything
// that was declared beside it.

/// An arrow on the player's screen pointing at a place.
public struct Waypoint: Codable, Hashable, Sendable {
    public var position: Vec3
    public var label: String
    public var color: ColorRGBA?

    public init(position: Vec3, label: String = "", color: ColorRGBA? = nil) {
        self.position = position
        self.label = String(label.prefix(40))
        self.color = color
    }
}

/// Something a player is carrying.
public struct InventoryItem: Codable, Hashable, Sendable, Identifiable {
    public static let maximumItems = 24
    public var name: String
    /// An emoji, or an SF Symbol name.
    public var icon: String
    public var count: Int

    public var id: String { name }

    public init(name: String, icon: String = "", count: Int = 1) {
        self.name = String(name.prefix(32))
        self.icon = String(icon.prefix(40))
        self.count = count
    }
}

/// A character talking to the player, with answers to pick.
public struct DialogBox: Codable, Hashable, Sendable {
    public static let maximumChoices = 4
    public var id: String
    public var speaker: String
    public var text: String
    public var choices: [String]

    public init(id: String, speaker: String, text: String, choices: [String]) {
        self.id = String(id.prefix(40))
        self.speaker = String(speaker.prefix(32))
        self.text = String(text.prefix(400))
        self.choices = Array(choices.prefix(Self.maximumChoices).map { String($0.prefix(40)) })
    }
}

public struct ShopOffer: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var price: Int
    public var icon: String

    public var id: String { name }

    public init(name: String, price: Int, icon: String = "") {
        self.name = String(name.prefix(32))
        self.price = Swift.max(0, price)
        self.icon = String(icon.prefix(40))
    }
}

/// A shop window on the player's screen.
public struct ShopPanel: Codable, Hashable, Sendable {
    public static let maximumOffers = 24
    public var id: String
    public var title: String
    /// What the prices are counted in, as shown ("coins").
    public var currency: String
    public var balance: Int
    public var offers: [ShopOffer]

    public init(id: String, title: String, currency: String, balance: Int, offers: [ShopOffer]) {
        self.id = String(id.prefix(40))
        self.title = String(title.prefix(40))
        self.currency = String(currency.prefix(20))
        self.balance = balance
        self.offers = Array(offers.prefix(Self.maximumOffers))
    }
}

/// A big timer on the screen.
public struct CountdownDisplay: Codable, Hashable, Sendable {
    public var label: String
    /// Seconds left when it was sent.
    public var seconds: Double

    public init(label: String, seconds: Double) {
        self.label = String(label.prefix(40))
        self.seconds = Swift.max(0, Swift.min(86_400, seconds.isFinite ? seconds : 0))
    }
}

public struct LeaderboardRow: Codable, Hashable, Sendable {
    public var name: String
    public var value: Double
}

/// A world's best scores, kept on the host's iPad between games.
public struct Leaderboard: Codable, Hashable, Sendable {
    public static let keptRows = 10
    public var title: String
    public var lowerIsBetter: Bool
    public private(set) var rows: [LeaderboardRow] = []

    public init(title: String, lowerIsBetter: Bool = false) {
        self.title = String(title.prefix(40))
        self.lowerIsBetter = lowerIsBetter
    }

    /// Keeps a player's best. True when the table changed.
    @discardableResult
    public mutating func submit(name: String, value: Double) -> Bool {
        guard value.isFinite else { return false }
        let name = String(name.prefix(AvatarProfile.maximumNameLength))
        if let index = rows.firstIndex(where: { $0.name == name }) {
            let old = rows[index].value
            guard lowerIsBetter ? value < old : value > old else { return false }
            rows[index].value = value
        } else {
            rows.append(LeaderboardRow(name: name, value: value))
        }
        let before = rows
        rows.sort { lowerIsBetter ? $0.value < $1.value : $0.value > $1.value }
        if rows.count > Self.keptRows { rows.removeLast(rows.count - Self.keptRows) }
        return rows != before || rows.contains { $0.name == name && $0.value == value }
    }

    public func rank(of name: String) -> Int? {
        rows.firstIndex { $0.name == name }.map { $0 + 1 }
    }
}

/// What the player sees of a leaderboard.
public struct LeaderboardPanel: Codable, Hashable, Sendable {
    public var title: String
    public var rows: [LeaderboardRow]
    public var lowerIsBetter: Bool

    public init(_ board: Leaderboard) {
        title = board.title
        rows = board.rows
        lowerIsBetter = board.lowerIsBetter
    }
}

/// Buttons the runtime puts on screens for its own parts — using a thing,
/// answering, buying, getting out of a vehicle — sent back like any script
/// button, and caught before the script's `on button` sees them.
public enum ReservedButton: Equatable, Sendable {
    case use(item: String)
    case choose(dialog: String, index: Int)
    case buy(shop: String, item: String)
    case closeDialog
    case closeShop
    case closeLeaderboard
    case exitVehicle

    static let prefix = "__"

    public var id: String {
        switch self {
        case let .use(item): return "__use:\(item)"
        case let .choose(dialog, index): return "__choice:\(index):\(dialog)"
        case let .buy(shop, item): return "__buy:\(shop):\(item)"
        case .closeDialog: return "__close:dialog"
        case .closeShop: return "__close:shop"
        case .closeLeaderboard: return "__close:board"
        case .exitVehicle: return "__exit_vehicle"
        }
    }

    public init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        let body = id.dropFirst(Self.prefix.count)
        if body.hasPrefix("use:") {
            self = .use(item: String(body.dropFirst(4)))
        } else if body.hasPrefix("choice:") {
            let rest = body.dropFirst(7)
            guard let colon = rest.firstIndex(of: ":"), let index = Int(rest[..<colon]) else { return nil }
            self = .choose(dialog: String(rest[rest.index(after: colon)...]), index: index)
        } else if body.hasPrefix("buy:") {
            let rest = body.dropFirst(4)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            self = .buy(shop: String(rest[..<colon]), item: String(rest[rest.index(after: colon)...]))
        } else if body == "close:dialog" {
            self = .closeDialog
        } else if body == "close:shop" {
            self = .closeShop
        } else if body == "close:board" {
            self = .closeLeaderboard
        } else if body == "exit_vehicle" {
            self = .exitVehicle
        } else {
            return nil
        }
    }
}
