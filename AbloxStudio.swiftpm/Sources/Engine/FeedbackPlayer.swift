import Foundation
import AudioToolbox
import AbloxCore
#if canImport(UIKit)
import UIKit
#endif

/// Plays the sound and haptic for a `SoundCue`, and the sound library's
/// recordings.
///
/// ## Where the sounds are
///
/// A Swift Playground should be readable Swift, not a bundle of binaries, so
/// the thirty cues' recordings are text inside the app (`CueRecordings`), and
/// the thousands in the sound library come down from the game list when a
/// game names one (`SoundLibraryStore`). A cue still has its few tones
/// (`SoundCue.tones`) for anyone who turns recordings off, and if the audio
/// engine cannot start, iOS's built-in sounds (`AudioServicesPlaySystemSoundID`)
/// stand in, as they always did.
///
/// ## Why haptics carry equal weight
///
/// These iPads are often muted — a classroom, a living room, a bus. The haptic
/// is frequently the only feedback that actually arrives, so every cue defines
/// one, and the throttle that stops a row of coins becoming a buzz lives in
/// `SoundCue.minimumInterval` alongside it.
@MainActor
public final class FeedbackPlayer {

    public var isSoundEnabled: Bool = true
    /// Told of every cue played, for sound captions.
    public var onPlayed: ((SoundCue) -> Void)?
    public var isHapticsEnabled: Bool = true
    /// Settings → Comfort → Vibration strength, 0 to 1.
    public var hapticIntensity: Double = 1
    /// Settings → Sound, 0 to 1.
    public var effectsVolume: Float = 1 {
        didSet { SoundSynth.shared.effectsGain = effectsVolume }
    }

    private var throttle = SoundThrottle()
    private let startedAt = Date()
    /// When each library sound last played, so a script calling one every
    /// frame is a sound, not a buzz.
    private var libraryPlayed: [String: Double] = [:]

    /// Settings → Sound library → "Recorded sounds". On: the cues play
    /// their recordings. Off: the tones they had before.
    nonisolated public static let recordedCuesKey = "ablox.recordedCues"
    nonisolated public static var usesRecordedCues: Bool {
        UserDefaults.standard.object(forKey: recordedCuesKey) as? Bool ?? true
    }

    #if canImport(UIKit)
    // Generators are kept rather than created per tap: creating one and using
    // it immediately gives a noticeably weaker tap, because the Taptic Engine
    // has not been warmed.
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    #endif

    public init() {}

    /// Prepares the haptic hardware. Call when entering play — the first tap
    /// after a cold start is otherwise late and weak.
    public func prepare() {
        // The recordings are decoded off the main thread, before the first
        // coin needs one.
        if Self.usesRecordedCues {
            DispatchQueue.global(qos: .userInitiated).async { CueRecordings.prepareAll() }
        }
        #if canImport(UIKit)
        guard isHapticsEnabled else { return }
        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
        notification.prepare()
        #endif
    }

    /// Plays a cue, or a library sound, named by a world's rule or script.
    ///
    /// An unknown name is ignored rather than defaulted: a typo in a rule
    /// should be silent, not play the wrong thing everywhere.
    public func play(named name: String) {
        if let cue = SoundCue.named(name) {
            play(cue)
        } else {
            playLibrary(SoundPlay(name: name))
        }
    }

    public func play(_ cue: SoundCue, volume: Float = 1, pitch: Float = 1) {
        let now = Date().timeIntervalSince(startedAt)
        guard throttle.shouldPlay(cue, at: now) else { return }
        onPlayed?(cue)

        if isSoundEnabled {
            let synth = SoundSynth.shared
            let recorded = Self.usesRecordedCues ? CueRecordings.clip(for: cue) : nil
            let played = recorded.map { synth.play($0, volume: volume, pitch: pitch) } ?? synth.play(cue, volume: volume, pitch: pitch)
            if !played { AudioServicesPlaySystemSound(systemSoundID(for: cue)) }
        }
        if isHapticsEnabled {
            playHaptic(cue.feedback)
        }
    }

    /// A sound a script asked for, louder or softer, higher or lower.
    public func play(_ request: SoundPlay) {
        if let cue = SoundCue.named(request.name) {
            play(cue, volume: request.volume, pitch: request.pitch)
        } else {
            playLibrary(request)
        }
    }

    /// A sound from the library: at once when it has been played before,
    /// otherwise as soon as it is read from the iPad — or downloaded, when
    /// that is quick. One that would arrive long after the moment it was
    /// for is left silent.
    private func playLibrary(_ request: SoundPlay) {
        let id = request.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isSoundEnabled, SoundLibrary.isLibraryID(id) else { return }
        let now = Date().timeIntervalSince(startedAt)
        if let last = libraryPlayed[id], now - last < 0.05 { return }
        libraryPlayed[id] = now
        if libraryPlayed.count > 400 { libraryPlayed = [id: now] }

        if let clip = SoundClipCache.shared.clip(for: id) {
            SoundSynth.shared.play(clip, volume: request.volume, pitch: request.pitch)
            return
        }
        let asked = Date()
        Task { @MainActor in
            guard let clip = await SoundLibraryStore.shared.clip(for: id),
                  Date().timeIntervalSince(asked) < 0.8 else { return }
            SoundSynth.shared.play(clip, volume: request.volume, pitch: request.pitch)
        }
    }

    /// Gets a world's library sounds ready before they are needed: read
    /// from the iPad, or downloaded, and decoded.
    public func prepareSounds(for world: WorldDocument) {
        let ids = SoundLibrary.ids(in: world)
        guard !ids.isEmpty else { return }
        Task { @MainActor in await SoundLibraryStore.shared.prepare(ids) }
    }

    /// iOS's built-in sound IDs. Chosen for character rather than meaning —
    /// these are the system's, not ours, so the mapping is about which one
    /// *feels* like a coin.
    private func systemSoundID(for cue: SoundCue) -> SystemSoundID {
        switch cue {
        case .collect: return 1057      // Tink
        case .checkpoint: return 1103   // Begin recording
        case .hurt: return 1053         // Low tri-tone
        case .bounce: return 1104       // End recording
        case .teleport: return 1112     // Key press click
        case .goal: return 1025         // Fanfare
        case .join: return 1003         // Received message
        case .leave: return 1004        // Sent message
        case .tick: return 1105         // Tock
        case .error: return 1073        // Alert
        case .shoot: return 1306        // Keyboard click
        case .hit: return 1104          // End recording
        case .reload: return 1105       // Tock
        case .defeat, .lose: return 1053 // Low tri-tone
        case .coin: return 1057
        case .jump, .whoosh, .pop: return 1104
        case .powerUp, .magic, .win: return 1025
        case .explosion, .drum: return 1073
        case .splash: return 1105
        case .door, .click: return 1306
        case .bell: return 1103
        case .laser: return 1306
        case .alarm: return 1005
        }
    }

    private func playHaptic(_ feedback: SoundCue.Feedback) {
        #if canImport(UIKit)
        // Notification taps have no strength of their own; a light setting
        // plays them as a soft tap instead.
        if hapticIntensity < 0.6, feedback == .success || feedback == .warning || feedback == .failure {
            lightImpact.impactOccurred(intensity: CGFloat(hapticIntensity))
            return
        }
        switch feedback {
        case .none: break
        case .light: lightImpact.impactOccurred(intensity: CGFloat(hapticIntensity))
        case .medium: mediumImpact.impactOccurred(intensity: CGFloat(hapticIntensity))
        case .heavy: heavyImpact.impactOccurred(intensity: CGFloat(hapticIntensity))
        case .success: notification.notificationOccurred(.success)
        case .warning: notification.notificationOccurred(.warning)
        case .failure: notification.notificationOccurred(.error)
        }
        #endif
    }

    /// Clears the throttle. Called between rounds, so the first coin of a new
    /// round is never swallowed by the last one of the previous.
    public func reset() {
        throttle.reset()
    }
}
