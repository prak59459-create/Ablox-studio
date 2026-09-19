import Foundation
import AudioToolbox
#if canImport(UIKit)
import UIKit
#endif

/// Plays the sound and haptic for a `SoundCue`.
///
/// ## Why system sounds rather than audio files
///
/// A Swift Playground should be readable Swift, not a bundle of binaries, and
/// ten `.caf` files would be ten things you cannot inspect or diff on an iPad.
/// `AudioServicesPlaySystemSoundID` plays iOS's built-in sounds with no assets
/// at all. They are not bespoke game sounds — a coin sounds like a system
/// "tink" — but they are immediate, they never fail to load, and they cost
/// nothing to ship.
///
/// Synthesising tones with `AVAudioEngine` would sound better and still need
/// no assets. It is the obvious next step if the feel matters more than the
/// footprint; it is not done here because it is a great deal more code to get
/// wrong in a layer that cannot be unit-tested.
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
    public var isHapticsEnabled: Bool = true

    private var throttle = SoundThrottle()
    private let startedAt = Date()

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
        #if canImport(UIKit)
        guard isHapticsEnabled else { return }
        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
        notification.prepare()
        #endif
    }

    /// Plays a cue named by a world's rule.
    ///
    /// An unknown name is ignored rather than defaulted: a typo in a rule
    /// should be silent, not play the wrong thing everywhere.
    public func play(named name: String) {
        guard let cue = SoundCue.named(name) else { return }
        play(cue)
    }

    public func play(_ cue: SoundCue) {
        let now = Date().timeIntervalSince(startedAt)
        guard throttle.shouldPlay(cue, at: now) else { return }

        if isSoundEnabled {
            AudioServicesPlaySystemSound(systemSoundID(for: cue))
        }
        if isHapticsEnabled {
            playHaptic(cue.feedback)
        }
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
        }
    }

    private func playHaptic(_ feedback: SoundCue.Feedback) {
        #if canImport(UIKit)
        switch feedback {
        case .none: break
        case .light: lightImpact.impactOccurred()
        case .medium: mediumImpact.impactOccurred()
        case .heavy: heavyImpact.impactOccurred()
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
