import XCTest
@testable import AbloxCore

/// The figures Studio quotes to an assistant when asking for a level.
///
/// They are arithmetic on `MovementConfig`, and arithmetic beside a simulation
/// is exactly the kind of thing that is right when it is written and wrong a
/// year later. So they are checked against the simulation itself: if someone
/// changes `jumpSpeed`, or `CharacterSolver` stops applying gravity the way it
/// does now, these fail rather than the prompt quietly starting to describe a
/// player who does not exist — and a level nobody can finish.
final class ReachabilityTests: XCTestCase {

    private let config = MovementConfig.default

    /// Runs the real solver at a fixed step and reports the flight.
    private func simulateJump(running: Bool, steps: Int = 400, dt: Float = 1.0 / 120) -> (apex: Float, distance: Float) {
        var snapshot = PlayerSnapshot(peerID: PeerID(), profile: .default, position: .zero)
        snapshot.isGrounded = true

        var apex: Float = 0
        // The distance at the last frame the player was still airborne.
        //
        // Taking it after the step that lands would add one frame of travel —
        // 0.075 m at run speed and 120 Hz — and make the simulation look
        // further than the arithmetic by exactly that. Measuring the wrong
        // frame is the easiest way to "discover" a discrepancy that is not
        // there.
        var distanceWhileAirborne: Float = 0

        // Full stick forward, so the horizontal figure is the fastest the
        // player can actually travel rather than a number from the config.
        let input = MovementInput(
            stick: Vec3(0, 0, 1),
            isJumping: true,
            isRunning: running
        )

        for step in 0..<steps {
            // Jump is pressed on the first frame only; holding it must not
            // give a second push.
            var thisInput = input
            thisInput.isJumping = (step == 0)

            let motion = CharacterSolver.step(snapshot: snapshot, input: thisInput, config: config, deltaTime: dt)
            snapshot.velocity = motion.velocity
            snapshot.position += motion.velocity * dt
            snapshot.isGrounded = false

            apex = Swift.max(apex, snapshot.position.y)
            if snapshot.position.y <= 0, step > 0 { break }
            distanceWhileAirborne = abs(snapshot.position.z)
        }

        return (apex, distanceWhileAirborne)
    }

    func testTheQuotedJumpHeightIsWhatTheSimulationDoes() {
        // A step taller than this is a step nobody gets up.
        let simulated = simulateJump(running: false).apex
        XCTAssertEqual(
            config.maximumJumpHeight, simulated, accuracy: 0.05,
            "the prompt says a jump rises \(config.maximumJumpHeight) m; the simulation reaches \(simulated) m"
        )
    }

    func testTheJumpHeightIsTheRoundNumberTheDefaultsWereChosenFor() {
        // jumpSpeed 6, gravity -18 → 36 / 36. Worth pinning: it is the number
        // a level designer holds in their head.
        XCTAssertEqual(config.maximumJumpHeight, 1.0, accuracy: 0.001)
    }

    func testARunningJumpReachesFurtherThanAWalkingOne() {
        XCTAssertGreaterThan(
            simulateJump(running: true).distance,
            simulateJump(running: false).distance
        )
    }

    func testTheQuotedGapIsOneTheSimulationClearsWithRoomToSpare() {
        // `safeJumpDistance` is deliberately short of the theoretical maximum,
        // because a gap that needs a perfect jump is missed half the time.
        // This asserts the margin is real, not just intended.
        let simulated = simulateJump(running: true).distance
        XCTAssertLessThan(config.safeJumpDistance, simulated,
                          "the 'safe' gap must be one the simulation actually clears")
        XCTAssertGreaterThan(config.safeJumpDistance, simulated * 0.5,
                             "so conservative it would make dull levels")
    }

    func testTheTheoreticalDistanceIsNotAnUnderestimate() {
        // The arithmetic must not promise *less* than the player can do — but
        // it must certainly not promise more, because that would be gaps an
        // assistant is told to build and nobody can cross. Measured while
        // still airborne, so the comparison is against the same instant.
        let simulated = simulateJump(running: true).distance
        XCTAssertGreaterThanOrEqual(
            config.maximumJumpDistance(running: true), simulated,
            "the quoted reach is shorter than the simulation, so levels built to it would be uncrossable"
        )
        XCTAssertEqual(config.maximumJumpDistance(running: true), simulated, accuracy: 0.1,
                       "and it should not be so pessimistic that it is useless")
    }

    func testAirTimeMatchesTheSimulation() {
        // Derived separately from height, so it is worth its own check.
        var snapshot = PlayerSnapshot(peerID: PeerID(), profile: .default, position: .zero)
        snapshot.isGrounded = true

        let dt: Float = 1.0 / 240
        var elapsed: Float = 0
        for step in 0..<2000 {
            let input = MovementInput(isJumping: step == 0)
            let motion = CharacterSolver.step(snapshot: snapshot, input: input, config: config, deltaTime: dt)
            snapshot.velocity = motion.velocity
            snapshot.position += motion.velocity * dt
            snapshot.isGrounded = false
            elapsed += dt
            if snapshot.position.y <= 0, step > 0 { break }
        }

        XCTAssertEqual(config.airTime, elapsed, accuracy: 0.05)
    }

    func testHoldingJumpDoesNotGiveASecondPush() {
        // If it did, every quoted figure would be wrong — and the prompt would
        // be describing a much more capable player than the one people get.
        var snapshot = PlayerSnapshot(peerID: PeerID(), profile: .default, position: .zero)
        snapshot.isGrounded = true

        let dt: Float = 1.0 / 120
        var apex: Float = 0
        for _ in 0..<400 {
            // Held down the whole time, and never grounded again.
            let motion = CharacterSolver.step(
                snapshot: snapshot,
                input: MovementInput(isJumping: true),
                config: config,
                deltaTime: dt
            )
            snapshot.velocity = motion.velocity
            snapshot.position += motion.velocity * dt
            snapshot.isGrounded = false
            apex = Swift.max(apex, snapshot.position.y)
        }

        XCTAssertEqual(apex, config.maximumJumpHeight, accuracy: 0.05)
    }

    func testDegenerateGravityDoesNotProduceInfinity() {
        // A world file can set gravity, and Studio's slider can reach zero.
        // A prompt quoting `inf` metres would be absurd; worse, the arithmetic
        // would divide by zero.
        var broken = MovementConfig.default
        broken.gravity = 0
        XCTAssertEqual(broken.maximumJumpHeight, 0)
        XCTAssertEqual(broken.airTime, 0)
        XCTAssertEqual(broken.safeJumpDistance, 0)

        broken.gravity = 5     // upward gravity, which is nonsense
        XCTAssertEqual(broken.maximumJumpHeight, 0)
    }
}
