import Foundation

// Waving, dancing, clapping — and emoji stamps over your head.
//
// A gesture goes to the host as a claim like any other input, is checked
// against these lists and a rate limit, and comes back to everyone as an
// effect, so every iPad plays the same animation on the same avatar. A
// world's script hears it as `on emote(p, name)`.

public enum Emote: String, CaseIterable, Sendable {
    case wave, dance, clap, cheer, bow, point, laugh, sit

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
        }
    }

    /// How long it plays. Sitting lasts until they move.
    public var seconds: Double {
        switch self {
        case .wave, .clap, .point: return 2
        case .dance: return 4
        case .cheer, .laugh: return 2.5
        case .bow: return 1.8
        case .sit: return 30
        }
    }
}

/// Emoji that can float over your head.
public enum Stamp {
    public static let all: [String] = ["😀", "😂", "👍", "❤️", "🎉", "😮", "😢", "😡", "🔥", "⭐️", "👋", "💯"]
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
