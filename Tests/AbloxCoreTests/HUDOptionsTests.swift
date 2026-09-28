import XCTest
@testable import AbloxCore

/// The play screen's options, the touch stick, the camera's habits, the
/// compass and a visit's stats.
final class HUDOptionsTests: XCTestCase {

    func testOptionsSurviveOlderAndNewerSaves() throws {
        var preferences = PlayPreferences()
        preferences.hud.showCompass = true
        preferences.hud.set(.camera, shown: false)
        preferences.hud.joystickStyle = .fixed
        preferences.hud.mapSize = .large
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(PlayPreferences.self, from: data), preferences)

        // Saved before the play-screen options existed: all the defaults.
        let old = try JSONDecoder().decode(PlayPreferences.self, from: Data(#"{"autoJump":true}"#.utf8))
        XCTAssertTrue(old.autoJump)
        XCTAssertEqual(old.hud, HUDOptions())

        // From a newer version: unknown names and values are skipped, the
        // rest kept, numbers put back in range.
        let newer = #"{"hud":{"showSpeed":true,"hiddenTopBar":["score","jetpack"],"mapSize":"huge","opacity":9,"stickDeadZone":-1}}"#
        let loaded = try JSONDecoder().decode(PlayPreferences.self, from: Data(newer.utf8)).hud
        XCTAssertTrue(loaded.showSpeed)
        XCTAssertEqual(loaded.hiddenTopBar, [.score])
        XCTAssertFalse(loaded.shows(.score))
        XCTAssertTrue(loaded.shows(.camera))
        XCTAssertEqual(loaded.mapSize, .small)
        XCTAssertEqual(loaded.opacity, 1)
        XCTAssertEqual(loaded.stickDeadZone, 0)
    }

    func testPresetsPlaceTheButtonsAndAreRecognised() {
        var preferences = PlayPreferences()
        XCTAssertTrue(ButtonPreset.standard.matches(preferences))
        for preset in ButtonPreset.allCases {
            preset.apply(to: &preferences)
            XCTAssertTrue(preset.matches(preferences), "\(preset)")
            XCTAssertEqual(ButtonPreset.allCases.filter { $0.matches(preferences) }, [preset])
            XCTAssertTrue(PlayPreferences.buttonScaleRange.contains(preferences.buttonScale))
        }
    }

    func testTouchStickDeadZoneEightWayAndRunning() {
        XCTAssertEqual(TouchStick.shape(x: 0.05, z: 0.05, deadZone: 0.1, eightWay: false, alwaysRun: false).stick, .zero)
        let full = TouchStick.shape(x: 0, z: 1, deadZone: 0.1, eightWay: false, alwaysRun: false)
        XCTAssertEqual(full.stick.z, 1, accuracy: 0.001)
        XCTAssertTrue(full.running)
        let gentle = TouchStick.shape(x: 0, z: 0.5, deadZone: 0, eightWay: false, alwaysRun: false)
        XCTAssertFalse(gentle.running)
        XCTAssertTrue(TouchStick.shape(x: 0, z: 0.5, deadZone: 0, eightWay: false, alwaysRun: true).running)
        // Nearly straight on becomes straight on; a rough diagonal a true one.
        let snapped = TouchStick.shape(x: 0.15, z: 0.9, deadZone: 0, eightWay: true, alwaysRun: false).stick
        XCTAssertEqual(snapped.x, 0, accuracy: 0.001)
        let diagonal = TouchStick.shape(x: 0.6, z: 0.5, deadZone: 0, eightWay: true, alwaysRun: false).stick
        XCTAssertEqual(diagonal.x, diagonal.z, accuracy: 0.001)
        XCTAssertEqual(TouchStick.shape(x: .nan, z: 1, deadZone: 0, eightWay: false, alwaysRun: false).stick, .zero)
        XCTAssertEqual(TouchStick.keepWalking(.zero), Vec3(0, 0, 1))
        XCTAssertEqual(TouchStick.keepWalking(Vec3(1, 0, 0)), Vec3(1, 0, 0))
    }

    func testTheCameraFollowsOnlyWhenWalkingOn() {
        // Facing east (yaw -90) with the camera looking north: swing round.
        let turn = CameraHabits.followTurn(cameraYaw: 0, bodyYaw: -90, stick: Vec3(0, 0, 1), seconds: 1.0 / 60)
        XCTAssertGreaterThan(turn, 0)
        XCTAssertLessThan(turn, 10, "gently")
        XCTAssertEqual(CameraHabits.followTurn(cameraYaw: 0, bodyYaw: -90, stick: .zero, seconds: 1.0 / 60), 0)
        XCTAssertEqual(CameraHabits.followTurn(cameraYaw: 0, bodyYaw: -90, stick: Vec3(1, 0, 0), seconds: 1.0 / 60), 0, "sideways")
        XCTAssertEqual(CameraHabits.followTurn(cameraYaw: 0, bodyYaw: -90, stick: Vec3(0, 0, -1), seconds: 1.0 / 60), 0, "towards it")
        XCTAssertEqual(CameraHabits.followTurn(cameraYaw: 90, bodyYaw: -91, stick: Vec3(0, 0, 1), seconds: 1.0 / 60), 0, "already behind")
        // The short way round, across ±180.
        XCTAssertLessThan(CameraHabits.followTurn(cameraYaw: -170, bodyYaw: -170, stick: Vec3(0, 0, 1), seconds: 0.05), 0)
        XCTAssertEqual(CameraHabits.behind(bodyYaw: 30), -30)
        let look = CameraHabits.look(dx: 4, dy: 2, invertX: true, verticalSpeed: 0.5)
        XCTAssertEqual(look.dx, -4)
        XCTAssertEqual(look.dy, 1)
    }

    func testCompassBearingsAndMarks() {
        XCTAssertEqual(Compass.bearing(cameraYaw: 0), 0)
        XCTAssertEqual(Compass.bearing(cameraYaw: -90), 90, "east")
        XCTAssertEqual(Compass.bearing(cameraYaw: 90), 270, "west")
        XCTAssertEqual(Compass.bearing(cameraYaw: 180), 180)
        XCTAssertEqual(Compass.bearing(cameraYaw: .nan), 0)
        let marks = Compass.marks(bearing: 0, span: 150)
        XCTAssertEqual(marks.map(\.bearing), [315, 0, 45])
        XCTAssertEqual(marks[1].position, 0)
        XCTAssertTrue(marks[1].isCardinal)
        XCTAssertFalse(marks[0].isCardinal)
        XCTAssertEqual(Compass.marks(bearing: 350, span: 40).map(\.bearing), [0])
        XCTAssertEqual(Compass.spoken(bearing: 44), Compass.spoken(bearing: 45))
        XCTAssertEqual(Compass.spoken(bearing: 359), Compass.spoken(bearing: 0))
    }

    func testAVisitCountsWalkingJumpsAndSpeedButNotTeleports() {
        var tally = VisitTally()
        tally.record(position: Vec3(0, 0, 0), grounded: true, time: 0)
        tally.record(position: Vec3(3, 0, 4), grounded: true, time: 1)
        XCTAssertEqual(tally.metresWalked, 5, accuracy: 0.001)
        XCTAssertEqual(tally.topSpeed, 5, accuracy: 0.001)
        tally.record(position: Vec3(3, 1, 4), grounded: false, time: 1.2)
        tally.record(position: Vec3(3, 0, 4), grounded: true, time: 1.6)
        tally.record(position: Vec3(3, 1, 4), grounded: false, time: 1.8)
        XCTAssertEqual(tally.jumps, 2)
        tally.record(position: Vec3(200, 0, 4), grounded: true, time: 2)
        XCTAssertEqual(tally.metresWalked, 5, accuracy: 0.001, "a respawn is not a walk")
        tally.lostTrack()
        tally.record(position: Vec3(0, 0, 0), grounded: true, time: 3)
        XCTAssertEqual(tally.metresWalked, 5, accuracy: 0.001)
        tally.record(position: Vec3(.nan, 0, 0), grounded: true, time: 4)
        XCTAssertEqual(tally.lastPosition, Vec3(0, 0, 0))
    }

    func testIdlePowerAndPlaces() {
        var idle = IdleWatch(now: 10)
        XCTAssertFalse(idle.isAway(at: 100))
        XCTAssertTrue(idle.isAway(at: 190))
        idle.touched(at: 185)
        XCTAssertFalse(idle.isAway(at: 190))

        XCTAssertEqual(PowerNotice.message(batteryLevel: 0.15, charging: false, heat: .nominal, alreadySaid: [])?.key, "battery")
        XCTAssertNil(PowerNotice.message(batteryLevel: 0.15, charging: true, heat: .nominal, alreadySaid: []))
        XCTAssertNil(PowerNotice.message(batteryLevel: -1, charging: false, heat: .fair, alreadySaid: []), "unknown battery")
        XCTAssertEqual(PowerNotice.message(batteryLevel: 0.1, charging: false, heat: .serious, alreadySaid: ["battery"])?.key, "heat")
        XCTAssertNil(PowerNotice.message(batteryLevel: 0.1, charging: false, heat: .serious, alreadySaid: ["battery", "heat"]))

        XCTAssertNil(Placing.place(of: 5, among: [5]), "alone")
        XCTAssertEqual(Placing.place(of: 5, among: [9, 5, 5, 1]), 2)
        XCTAssertEqual(Placing.place(of: 1, among: [9, 5, 5, 1]), 4)
        XCTAssertEqual(Placing.ordinal(1), L("{}st", 1))
        XCTAssertEqual(Placing.ordinal(12), L("{}th", 12))
        XCTAssertEqual(Placing.ordinal(22), L("{}nd", 22))
        let keys = PlayShortcuts.all.map(\.keys)
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
