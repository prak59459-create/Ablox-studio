import XCTest
@testable import AbloxCore

final class RealCameraTests: XCTestCase {

    private let frame: Float = 1.0 / 60

    func testStandingStillDoesNotMoveTheView() {
        var head = RealCamera()
        var pose = RealCamera.Pose.still
        for _ in 0..<120 {
            pose = head.step(velocity: .zero, grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame)
        }
        XCTAssertEqual(pose, .still)
    }

    func testRunningBobsTheView() {
        var head = RealCamera()
        var heights: [Float] = []
        var sides: [Float] = []
        for _ in 0..<180 {
            let pose = head.step(velocity: Vec3(0, 0, -9), grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame)
            heights.append(pose.offset.y)
            sides.append(pose.offset.x)
        }
        let late = heights.suffix(60)
        XCTAssertGreaterThan(late.max()! - late.min()!, 0.04, "steps should show")
        XCTAssertLessThan(late.map(abs).max()!, 0.1, "but only a little")
        XCTAssertGreaterThan(sides.suffix(60).max()!, 0.01)
        XCTAssertLessThan(sides.suffix(60).min()!, -0.01)
    }

    func testGentleKeepsAboutAThird() {
        var full = RealCamera()
        var soft = RealCamera()
        var a: Float = 0, b: Float = 0
        for _ in 0..<100 {
            a = max(a, abs(full.step(velocity: Vec3(9, 0, 0), grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame).rollDegrees))
            b = max(b, abs(soft.step(velocity: Vec3(9, 0, 0), grounded: true, yawDegrees: 0, gentle: true, deltaTime: frame).rollDegrees))
        }
        XCTAssertEqual(b, a * 0.35, accuracy: 0.01)
    }

    func testAHardLandingDipsAndSpringsBack() {
        var head = RealCamera()
        _ = head.step(velocity: .zero, grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame)
        for _ in 0..<30 {
            _ = head.step(velocity: Vec3(0, -15, 0), grounded: false, yawDegrees: 0, gentle: false, deltaTime: frame)
        }
        let landed = head.step(velocity: .zero, grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame)
        XCTAssertLessThan(landed.offset.y, -0.15)
        XCTAssertLessThan(landed.pitchDegrees, -2, "the head nods down")
        XCTAssertLessThanOrEqual(head.dip, RealCamera.maximumDip)
        var pose = landed
        for _ in 0..<120 {
            pose = head.step(velocity: .zero, grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame)
        }
        XCTAssertEqual(pose.offset.y, 0, accuracy: 0.005)
    }

    func testAHopDoesNotDip() {
        var head = RealCamera()
        for _ in 0..<10 {
            _ = head.step(velocity: Vec3(0, -1.5, 0), grounded: false, yawDegrees: 0, gentle: false, deltaTime: frame)
        }
        let landed = head.step(velocity: .zero, grounded: true, yawDegrees: 0, gentle: false, deltaTime: frame)
        XCTAssertEqual(landed.offset.y, 0, accuracy: 1e-4)
    }

    func testTurningTipsIntoTheTurn() {
        var head = RealCamera()
        var pose = RealCamera.Pose.still
        var yaw: Float = 0
        for _ in 0..<30 {
            yaw += 3 // 180° a second
            pose = head.step(velocity: .zero, grounded: true, yawDegrees: yaw, gentle: false, deltaTime: frame)
        }
        XCTAssertLessThan(pose.rollDegrees, -0.5)
        XCTAssertGreaterThanOrEqual(pose.rollDegrees, -3)
        // Across ±180 is a small turn, not a spin.
        var wrap = RealCamera()
        _ = wrap.step(velocity: .zero, grounded: true, yawDegrees: 179, gentle: false, deltaTime: frame)
        let across = wrap.step(velocity: .zero, grounded: true, yawDegrees: -179, gentle: false, deltaTime: frame)
        XCTAssertLessThan(abs(across.rollDegrees), 0.5)
    }

    func testRealModeIsOffUntilChosenAndRemembered() throws {
        XCTAssertFalse(PlayPreferences().realMode)
        var preferences = PlayPreferences()
        preferences.realMode = true
        let again = try JSONDecoder().decode(PlayPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(again.realMode)
        let old = try JSONDecoder().decode(PlayPreferences.self, from: Data(#"{"cameraShake":false}"#.utf8))
        XCTAssertFalse(old.realMode)
        XCTAssertFalse(old.cameraShake)
    }

    // MARK: Sliding

    func testASlideKeepsGoingTheWayItStarted() {
        var snapshot = PlayerSnapshot(peerID: PeerID(), velocity: Vec3(0, 0, -12), isGrounded: true)
        // The stick pushed sideways and then let go: a slide does not steer or stop.
        let sideways = MovementInput(stick: Vec3(1, 0, 0))
        for step in 0..<60 {
            let input = step < 30 ? sideways : .idle
            let result = CharacterSolver.step(snapshot: snapshot, input: input, slides: true, deltaTime: frame)
            snapshot.velocity = Vec3(result.velocity.x, 0, result.velocity.z)
            snapshot.yawDegrees = result.yawDegrees
        }
        XCTAssertEqual(snapshot.velocity.x, 0, accuracy: 1e-4)
        XCTAssertLessThan(snapshot.velocity.z, -12 * 0.6, "a second on, most of the speed is left")
        XCTAssertGreaterThan(snapshot.velocity.z, -12)
        XCTAssertEqual(snapshot.yawDegrees, 0)

        // Without the slide the same stick turns and the same let-go stops.
        var walking = PlayerSnapshot(peerID: PeerID(), velocity: Vec3(0, 0, -12), isGrounded: true)
        for _ in 0..<60 {
            walking.velocity = CharacterSolver.step(snapshot: walking, input: .idle, deltaTime: frame).velocity
        }
        XCTAssertGreaterThan(walking.velocity.z, -0.5)
    }

    func testYouCanJumpOutOfASlide() {
        let snapshot = PlayerSnapshot(peerID: PeerID(), velocity: Vec3(0, 0, -10), isGrounded: true)
        let result = CharacterSolver.step(snapshot: snapshot, input: MovementInput(isJumping: true), slides: true, deltaTime: frame)
        XCTAssertEqual(result.velocity.y, MovementConfig.default.jumpSpeed, accuracy: 1e-4)
        XCTAssertLessThan(result.velocity.z, -9.9)
    }
}
