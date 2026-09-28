import Foundation

// Waving, dancing, clapping — and emoji stamps over your head.
//
// A gesture goes to the host as a claim like any other input, is checked
// against these lists and a rate limit, and comes back to everyone as an
// effect, so every iPad plays the same animation on the same avatar. A
// world's script hears it as `on emote(p, name)`.

public enum Emote: String, CaseIterable, Sendable {
    case wave, dance, clap, cheer, bow, point, laugh, sit
    // Added later. An iPad that has not updated ignores them.
    case hop, spin, flex, shrug, think, facepalm, salute
    case thumbsUp = "thumbs_up", heartHands = "heart_hands"
    case yawn, stretch, dab, floss, robot, flip, cry, stomp, victory, guitar, peace

    public var displayName: String {
        switch self {
        case .wave: return L("Wave")
        case .dance: return L("Dance")
        case .clap: return L("Clap")
        case .cheer: return L("Cheer")
        case .bow: return L("Bow")
        case .point: return L("Point")
        case .laugh: return L("Laugh")
        case .sit: return L("Sit")
        case .hop: return L("Hop for joy")
        case .spin: return L("Spin")
        case .flex: return L("Flex")
        case .shrug: return L("Shrug")
        case .think: return L("Think")
        case .facepalm: return L("Facepalm")
        case .salute: return L("Salute")
        case .thumbsUp: return L("Thumbs up")
        case .heartHands: return L("Heart hands")
        case .yawn: return L("Yawn")
        case .stretch: return L("Stretch")
        case .dab: return L("Dab")
        case .floss: return L("Floss")
        case .robot: return L("Robot dance")
        case .flip: return L("Flip")
        case .cry: return L("Cry")
        case .stomp: return L("Stomp")
        case .victory: return L("Victory")
        case .guitar: return L("Air guitar")
        case .peace: return L("Peace")
        }
    }

    public var symbolName: String {
        switch self {
        case .wave: return "hand.wave.fill"
        case .dance: return "figure.dance"
        case .clap: return "hands.clap.fill"
        case .cheer: return "figure.arms.open"
        case .bow: return "figure.cooldown"
        case .point: return "hand.point.up.left.fill"
        case .laugh: return "face.smiling.inverse"
        case .sit: return "chair.lounge.fill"
        case .hop: return "figure.jumprope"
        case .spin: return "arrow.triangle.2.circlepath"
        case .flex: return "figure.strengthtraining.traditional"
        case .shrug: return "questionmark.circle"
        case .think: return "brain.head.profile"
        case .facepalm: return "hand.raised.fill"
        case .salute: return "hand.raised.fingers.spread.fill"
        case .thumbsUp: return "hand.thumbsup.fill"
        case .heartHands: return "heart.fill"
        case .yawn: return "moon.zzz.fill"
        case .stretch: return "figure.flexibility"
        case .dab: return "figure.cross.training"
        case .floss: return "figure.socialdance"
        case .robot: return "cpu"
        case .flip: return "arrow.counterclockwise.circle"
        case .cry: return "cloud.drizzle.fill"
        case .stomp: return "shoeprints.fill"
        case .victory: return "trophy.fill"
        case .guitar: return "guitars.fill"
        case .peace: return "hands.sparkles.fill"
        }
    }

    /// How long it plays. Sitting lasts until they move.
    public var seconds: Double {
        switch self {
        case .wave, .clap, .point, .salute, .thumbsUp, .peace: return 2
        case .dance, .floss, .robot, .guitar: return 4
        case .cheer, .laugh, .spin, .hop, .victory, .stomp: return 2.5
        case .bow: return 1.8
        case .flip: return 1.2
        case .flex, .shrug, .think, .facepalm, .heartHands, .dab: return 2.2
        case .yawn, .stretch, .cry: return 3
        case .sit: return 30
        }
    }
}

/// Up to four emotes kept first in the list and on keys 1 to 4, and the
/// one played on winning a round.
public struct EmoteFavourites: Codable, Hashable, Sendable {
    public static let maximum = 4
    /// Stored by name, so an emote an older version does not know is kept
    /// rather than lost.
    private var names: [String] = []
    private var victoryName: String?

    public init() {}

    public var emotes: [Emote] { names.compactMap(Emote.init(rawValue:)) }

    public func contains(_ emote: Emote) -> Bool { names.contains(emote.rawValue) }

    /// Adds or removes one; false when adding to a full set.
    @discardableResult
    public mutating func toggle(_ emote: Emote) -> Bool {
        if let index = names.firstIndex(of: emote.rawValue) {
            names.remove(at: index)
            return true
        }
        guard names.count < Self.maximum else { return false }
        names.append(emote.rawValue)
        return true
    }

    /// Favourites first, then the rest in their usual order.
    public var ordered: [Emote] {
        let first = emotes
        return first + Emote.allCases.filter { !first.contains($0) }
    }

    /// The favourite in `slot` (from 0), if there is one.
    public func emote(inSlot slot: Int) -> Emote? {
        let list = emotes
        return list.indices.contains(slot) ? list[slot] : nil
    }

    /// Played by itself on winning a round; nil for none.
    public var victory: Emote? {
        get { victoryName.flatMap(Emote.init(rawValue:)) }
        set { victoryName = newValue?.rawValue }
    }
}

/// Emoji that can float over your head.
public enum Stamp {
    public static let all: [String] = ["😀", "😂", "👍", "❤️", "🎉", "😮", "😢", "😡", "🔥", "⭐️", "👋", "💯",
                                      // Added later.
                                      "😎", "🤔", "😴", "🥳", "😱", "🤩", "👏", "🙏", "🏆", "🍕", "🐱", "🌈"]
}

public enum Gesture: Hashable, Sendable {
    case emote(Emote)
    case stamp(String)

    /// "wave", or "stamp:🎉" — what travels in the packet.
    public init?(wire: String) {
        if let emote = Emote(rawValue: wire) {
            self = .emote(emote)
        } else if wire.hasPrefix("stamp:"), Stamp.all.contains(String(wire.dropFirst(6))) {
            self = .stamp(String(wire.dropFirst(6)))
        } else {
            return nil
        }
    }

    public var wire: String {
        switch self {
        case let .emote(emote): return emote.rawValue
        case let .stamp(emoji): return "stamp:" + emoji
        }
    }

    /// Seconds between one person's gestures, so a held finger is not a flood.
    public static let minimumInterval: Double = 0.8
}
