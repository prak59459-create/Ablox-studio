import Foundation

/// The named sounds a world can ask for.
///
/// `EventAction.playSound(name:)` carries a string, because a world file
/// should stay readable and an author should be able to type one. This is the
/// closed set the client knows how to play; anything else falls back rather
/// than failing.
///
/// Lives in `AbloxCore` so the name→cue mapping is testable, and so Studio can
/// offer the same list in its rule editor rather than a free-text field that
/// silently does nothing when misspelled.
public enum SoundCue: String, CaseIterable, Sendable {
    case collect
    case checkpoint
    case hurt
    case bounce
    case teleport
    case goal
    case join
    case leave
    case tick
    case error

    /// How strongly the cue should be felt, independent of sound.
    ///
    /// Haptics carry more of the feel than audio on an iPad that is often
    /// muted in a classroom — which is exactly where this app is used.
    public enum Feedback: String, Sendable {
        case none
        case light
        case medium
        case heavy
        case success
        case warning
        case failure
    }

    public var feedback: Feedback {
        switch self {
        case .collect: return .light
        case .checkpoint: return .success
        case .hurt: return .failure
        case .bounce: return .medium
        case .teleport: return .medium
        case .goal: return .success
        case .join: return .light
        case .leave: return .light
        case .tick: return .none
        case .error: return .warning
        }
    }

    /// Whether repeats should be throttled.
    ///
    /// Collecting a row of coins fires this many times a second; a haptic per
    /// coin turns into a buzz rather than a series of taps.
    public var minimumInterval: Double {
        switch self {
        case .collect, .tick: return 0.08
        case .bounce: return 0.15
        default: return 0.0
        }
    }

    /// Resolves an authored name, case- and whitespace-insensitively.
    ///
    /// Returns nil rather than a default, so the caller can decide: the
    /// runtime stays silent, while Studio can flag the name as unknown.
    public static func named(_ raw: String) -> SoundCue? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SoundCue(rawValue: key)
    }

    /// The label in Studio's sound picker.
    ///
    /// Spelled out rather than derived from `rawValue`, for two reasons: a
    /// capitalised raw value cannot be translated (there is nothing to look
    /// up), and "Join" alone does not say whose join it is. `rawValue` stays
    /// the wire format, which must not change with the UI language.
    public var displayName: String {
        switch self {
        case .collect: return L("Collect")
        case .checkpoint: return L("Checkpoint reached")
        case .hurt: return L("Hurt")
        case .bounce: return L("Bounce")
        case .teleport: return L("Teleport")
        case .goal: return L("Goal")
        case .join: return L("Player joined")
        case .leave: return L("Player left")
        case .tick: return L("Tick")
        case .error: return L("Error")
        }
    }
}

// MARK: - Throttling

/// Suppresses cues that would fire faster than they can be felt.
///
/// Separated from playback so the rate limiting is testable without an audio
/// session — and so the same rule applies to haptics, which is where it
/// actually matters.
public struct SoundThrottle: Sendable {
    private var lastPlayed: [SoundCue: Double] = [:]

    public init() {}

    /// Whether `cue` should play now.
    public mutating func shouldPlay(_ cue: SoundCue, at time: Double) -> Bool {
        let interval = cue.minimumInterval
        guard interval > 0 else { return true }

        if let last = lastPlayed[cue], time - last < interval {
            return false
        }
        lastPlayed[cue] = time
        return true
    }

    public mutating func reset() {
        lastPlayed.removeAll()
    }
}
