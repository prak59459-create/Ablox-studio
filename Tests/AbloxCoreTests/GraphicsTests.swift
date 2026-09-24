import XCTest
@testable import AbloxCore

final class GraphicsTests: XCTestCase {

    private func run(_ governor: inout FrameRateGovernor, fps: Double, seconds: Double) -> [GraphicsProfile.Level] {
        var changes: [GraphicsProfile.Level] = []
        let frames = Int(fps * seconds)
        for _ in 0..<frames {
            if let level = governor.record(frameTime: 1 / fps) { changes.append(level) }
        }
        return changes
    }

    func testEachLevelSpendsLessThanTheOneAbove() {
        let high = GraphicsProfile.profile(for: .high)
        let medium = GraphicsProfile.profile(for: .medium)
        let low = GraphicsProfile.profile(for: .low)
        XCTAssertNil(low.shadowDistance)
        XCTAssertLessThan(medium.shadowDistance!, high.shadowDistance!)
        XCTAssertLessThan(low.resolutionScale, medium.resolutionScale)
        XCTAssertLessThan(medium.resolutionScale, high.resolutionScale)
        XCTAssertLessThan(low.viewDistance!, medium.viewDistance!)
        XCTAssertLessThan(low.roundSegments, high.roundSegments)
        XCTAssertLessThan(low.sphereRings, high.sphereRings)
    }

    func testASlowGameStepsDownUntilItIsFastEnough() {
        var governor = FrameRateGovernor()
        XCTAssertEqual(run(&governor, fps: 20, seconds: 2.5), [.medium])
        XCTAssertEqual(run(&governor, fps: 22, seconds: 2.5), [.low])
        // Nothing lower to go to.
        XCTAssertEqual(run(&governor, fps: 20, seconds: 5), [])
        XCTAssertEqual(governor.level, .low)
        XCTAssertEqual(governor.framesPerSecond, 20, accuracy: 1)
    }

    func testOneStutterDoesNotChangeAnything() {
        var governor = FrameRateGovernor()
        XCTAssertEqual(run(&governor, fps: 60, seconds: 3), [])
        XCTAssertEqual(run(&governor, fps: 20, seconds: 1.2), [])
        XCTAssertEqual(run(&governor, fps: 60, seconds: 3), [])
        XCTAssertEqual(governor.level, .high)
    }

    func testAFastGameStepsBackUpButNotStraightBackToALevelThatWasTooSlow() {
        var governor = FrameRateGovernor()
        XCTAssertEqual(run(&governor, fps: 20, seconds: 2.5), [.medium])
        // Fast at medium, but high was too slow a moment ago.
        XCTAssertEqual(run(&governor, fps: 60, seconds: 30), [])
        // A minute later it tries again.
        XCTAssertEqual(run(&governor, fps: 60, seconds: 40), [.high])
    }

    func testPausesAreNotCountedAsSlowFrames() {
        var governor = FrameRateGovernor()
        for _ in 0..<10 { XCTAssertNil(governor.record(frameTime: 2)) }
        XCTAssertNil(governor.record(frameTime: .nan))
        XCTAssertNil(governor.record(frameTime: 0))
        XCTAssertEqual(governor.level, .high)
    }

    func testEveryQualityHasANameAndAnExplanation() {
        for quality in GraphicsQuality.allCases {
            XCTAssertFalse(quality.displayName.isEmpty)
            XCTAssertFalse(quality.detail.isEmpty)
        }
        XCTAssertNil(GraphicsQuality.auto.fixedLevel)
        XCTAssertEqual(GraphicsQuality.low.fixedLevel, .low)
    }
}
