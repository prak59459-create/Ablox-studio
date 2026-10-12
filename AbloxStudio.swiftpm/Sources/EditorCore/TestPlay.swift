import Foundation

/// Studio's Play button: the world played as the game plays it, with a
/// character to walk, its scripts running and their buttons on the screen.
///
/// Play used to switch on physics in the editor's own view and nothing else:
/// no character, no scripts, so a game could not be tried at all (2026-10-12,
/// from the suggestion box). The physics view is still there as Preview.
public enum TestPlay {

    /// What Play opens.
    public enum Choice: Equatable, Sendable {
        /// The game, full screen, as Ablox runs it alone.
        case game
        /// Physics in the editor's view, without a character.
        case preview
    }

    /// While this iPad shares the project with other builders, its room
    /// already holds the game's network port, which a test game also opens;
    /// then only the preview can run until sharing stops.
    public static func choice(isSharingFromHere: Bool) -> Choice {
        isSharingFromHere ? .preview : .game
    }

    /// The world to test: just as it is in the editor now. A world whose
    /// scripts come from GitHub would otherwise fetch them again on play,
    /// and the test would run the copy online rather than the one being
    /// written.
    public static func world(_ world: WorldDocument) -> WorldDocument {
        var tested = world
        tested.scriptSource?.updatesOnPlay = false
        return tested
    }
}
