import XCTest
@testable import AbloxCore

final class SoundCueTests: XCTestCase {

    func testNamesResolveCaseAndWhitespaceInsensitively() {
        XCTAssertEqual(SoundCue.named("collect"), .collect)
        XCTAssertEqual(SoundCue.named("COLLECT"), .collect)
        XCTAssertEqual(SoundCue.named("  Collect  "), .collect)
    }

    func testAnUnknownNameResolvesToNothing() {
        // Deliberately not a default: a typo in a rule should be silent, not
        // play the wrong thing in every world that has it.
        XCTAssertNil(SoundCue.named("kerplunk"))
        XCTAssertNil(SoundCue.named(""))
    }

    func testEveryCueTheEngineEmitsIsKnown() {
        // These strings are hard-coded in EventMachine's built-in behaviours.
        // If one is renamed without updating the cue list it goes silent, and
        // nothing else would catch it.
        for name in ["collect", "checkpoint", "hurt", "bounce", "teleport"] {
            XCTAssertNotNil(SoundCue.named(name), "\(name) is emitted but has no cue")
        }
    }

    func testEveryCueHasFeedbackDefined() {
        for cue in SoundCue.allCases {
            // `.none` is a valid choice; the point is that every cue made one.
            _ = cue.feedback
            XCTAssertFalse(cue.displayName.isEmpty)
        }
    }

    func testQuietCuesStillCarryAHaptic() {
        // On a muted iPad in a classroom the haptic is the only feedback that
        // arrives, so the cues that matter must define one.
        for cue in [SoundCue.collect, .checkpoint, .hurt, .goal] {
            XCTAssertNotEqual(cue.feedback, SoundCue.Feedback.none, "\(cue) needs to be felt when muted")
        }
    }

    // MARK: Throttling

    func testRapidRepeatsAreThrottled() {
        // A row of coins fires this many times a second; without throttling
        // the haptics become a buzz rather than a series of taps.
        var throttle = SoundThrottle()
        XCTAssertTrue(throttle.shouldPlay(.collect, at: 0))
        XCTAssertFalse(throttle.shouldPlay(.collect, at: 0.02))
        XCTAssertFalse(throttle.shouldPlay(.collect, at: 0.05))
        XCTAssertTrue(throttle.shouldPlay(.collect, at: 0.2))
    }

    func testThrottlingIsPerCue() {
        var throttle = SoundThrottle()
        XCTAssertTrue(throttle.shouldPlay(.collect, at: 0))
        XCTAssertTrue(throttle.shouldPlay(.bounce, at: 0),
                      "one cue firing must not silence a different one")
    }

    func testUnthrottledCuesAlwaysPlay() {
        var throttle = SoundThrottle()
        for step in 0..<10 {
            XCTAssertTrue(throttle.shouldPlay(.goal, at: Double(step) * 0.001),
                          "reaching the goal is never spam")
        }
    }

    func testResetClearsTheThrottle() {
        // Between rounds, so the first coin of a new round is not swallowed by
        // the last one of the previous.
        var throttle = SoundThrottle()
        XCTAssertTrue(throttle.shouldPlay(.collect, at: 0))
        XCTAssertFalse(throttle.shouldPlay(.collect, at: 0.01))
        throttle.reset()
        XCTAssertTrue(throttle.shouldPlay(.collect, at: 0.02))
    }
}
