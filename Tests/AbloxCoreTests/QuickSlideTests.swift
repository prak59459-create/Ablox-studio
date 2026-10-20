import XCTest
@testable import AbloxCore

/// The slide button every game has: the move, when it may start, the pose
/// the other iPads are told about, and its place in the options.
final class QuickSlideTests: RuntimeTestCase {

    func testASlideGoesTheWayTheyWereGoingHalfAsFastAgain() throws {
        var slide = QuickSlide()
        let started = try XCTUnwrap(slide.start(velocity: Vec3(8, -2, 0), yawDegrees: 0, walkSpeed: 5))
        XCTAssertEqual(started.x, 12, accuracy: 0.001)
        XCTAssertEqual(started.y, -2, accuracy: 0.001, "up and down are kept, so a slide off a jump still falls")
        XCTAssertEqual(started.z, 0, accuracy: 0.001)
        XCTAssertTrue(slide.isSliding)
    }

    func testFromAStandItGoesTheWayTheyFaceAtWalkingSpeedAndAHalf() throws {
        var slide = QuickSlide()
        // Facing yaw 0 is -Z, as the character solver turns them.
        let ahead = try XCTUnwrap(slide.start(velocity: .zero, yawDegrees: 0, walkSpeed: 5))
        XCTAssertEqual(ahead.z, -7.5, accuracy: 0.001)
        XCTAssertEqual(ahead.x, 0, accuracy: 0.001)

        var turned = QuickSlide()
        let right = try XCTUnwrap(turned.start(velocity: .zero, yawDegrees: 90, walkSpeed: 5))
        XCTAssertEqual(right.x, 7.5, accuracy: 0.001)
    }

    func testItLastsASecondThenRestsBeforeTheNext() {
        var slide = QuickSlide()
        XCTAssertNotNil(slide.start(velocity: .zero, yawDegrees: 0, walkSpeed: 5))
        XCTAssertNil(slide.start(velocity: .zero, yawDegrees: 0, walkSpeed: 5), "not while sliding")
        slide.advance(by: 0.6)
        XCTAssertTrue(slide.isSliding)
        slide.advance(by: 0.5)
        XCTAssertFalse(slide.isSliding)
        XCTAssertNil(slide.start(velocity: .zero, yawDegrees: 0, walkSpeed: 5), "resting")
        slide.advance(by: 1.2)
        XCTAssertNotNil(slide.start(velocity: .zero, yawDegrees: 0, walkSpeed: 5))
        slide.stop()
        XCTAssertFalse(slide.isSliding)
    }

    func testOnlyOnFootAndFreeToMove() {
        XCTAssertTrue(QuickSlide.allowed(frozen: false, ride: .none, surroundings: .normal, speedScale: 1))
        XCTAssertFalse(QuickSlide.allowed(frozen: true, ride: .none, surroundings: .normal, speedScale: 1))
        XCTAssertFalse(QuickSlide.allowed(frozen: false, ride: .car, surroundings: .normal, speedScale: 1))
        XCTAssertFalse(QuickSlide.allowed(frozen: false, ride: .slide, surroundings: .normal, speedScale: 1),
                       "a game's own slide is already going")
        XCTAssertFalse(QuickSlide.allowed(frozen: false, ride: .none, surroundings: .water(surface: 2), speedScale: 1))
        XCTAssertFalse(QuickSlide.allowed(frozen: false, ride: .none, surroundings: .ladder, speedScale: 1))
        XCTAssertFalse(QuickSlide.allowed(frozen: false, ride: .none, surroundings: .normal, speedScale: 0))
    }

    func testTheSolverKeepsASlideGoingWithTheStickLetGo() {
        let snapshot = PlayerSnapshot(peerID: alice, velocity: Vec3(0, 0, -7.5), isGrounded: true)
        let motion = CharacterSolver.step(snapshot: snapshot, input: MovementInput(), slides: true, deltaTime: 0.1)
        XCTAssertLessThan(motion.velocity.z, -7, "only slowly loses speed")
    }

    func testOtherIPadsAreToldButAGamesEmoteHandlerIsNot() {
        XCTAssertEqual(Gesture(wire: "move:slide"), .slide)
        XCTAssertEqual(Gesture.slide.wire, "move:slide")
        XCTAssertNil(Emote(rawValue: "move:slide"), "not in the emote menus")

        let game = game(#"""
        on emote(p, name)
          print("emote " + name)
        end
        """#)
        startWithBoth(game)
        let effects = game.handle(.gesture("move:slide"), from: bob, at: 1)
        let wires = effects.compactMap { effect -> String? in
            guard case let .script(.gesture(speaker, wire)) = effect.action, speaker == bob else { return nil }
            return wire
        }
        XCTAssertEqual(wires, ["move:slide"])
        XCTAssertEqual(game.drainOutput(), [])
        XCTAssertEqual(game.drainErrors().map(\.message), [])
    }

    func testTheButtonIsOnUnlessTurnedOffAndOlderSavesGetIt() throws {
        XCTAssertTrue(HUDOptions().showSlideButton)
        let old = try JSONDecoder().decode(PlayPreferences.self, from: Data(#"{"hud":{"showRunButton":true}}"#.utf8)).hud
        XCTAssertTrue(old.showSlideButton)
        XCTAssertTrue(old.showRunButton, "a run button someone turned on stays")

        var off = PlayPreferences()
        off.hud.showSlideButton = false
        let data = try JSONEncoder().encode(off)
        XCTAssertFalse(try JSONDecoder().decode(PlayPreferences.self, from: data).hud.showSlideButton)
    }
}
