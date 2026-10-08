import XCTest
@testable import AbloxCore

/// The face is the front: a body drawn for a bearing looks the way it walks,
/// and shift lock turns it to where the camera looks.
final class FacingTests: XCTestCase {

    private func assertClose(_ a: Vec3, _ b: Vec3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-4, file: file, line: line)
    }

    func testTheFaceLooksTheWayTheStickWalks() {
        // Every stick direction, every camera: the drawn face points along
        // the walk, not mirrored left for right.
        for camera in stride(from: Float(-180), through: 180, by: 30) {
            for (x, z) in [(Float(1), Float(0)), (-1, 0), (0, 1), (0, -1), (0.7, 0.7), (-0.6, 0.8)] {
                let input = MovementInput(stick: Vec3(x, 0, z), cameraYawDegrees: camera)
                var snapshot = PlayerSnapshot(peerID: PeerID())
                snapshot.isGrounded = true
                var yaw = snapshot.yawDegrees
                for _ in 0..<60 {
                    snapshot.yawDegrees = yaw
                    yaw = CharacterSolver.step(snapshot: snapshot, input: input, deltaTime: 1.0 / 30).yawDegrees
                }
                snapshot.yawDegrees = yaw
                let velocity = CharacterSolver.step(snapshot: snapshot, input: input, deltaTime: 1.0 / 30).velocity
                let walk = Vec3(velocity.x, 0, velocity.z).normalized
                assertClose(Facing.forward(yawDegrees: yaw), walk)
            }
        }
    }

    func testWalkingRightFacesRight() {
        // The case a child saw: stick right with the camera behind, face +x.
        assertClose(Facing.forward(yawDegrees: Facing.yaw(toward: Vec3(1, 0, 0))), Vec3(1, 0, 0))
        assertClose(Facing.forward(yawDegrees: 0), Vec3(0, 0, -1))
    }

    func testRotationRoundTrips() {
        for yaw in stride(from: Float(-170), through: 180, by: 10) {
            XCTAssertEqual(normalizeDegrees(Facing.yawDegrees(of: Facing.rotation(yawDegrees: yaw)) - yaw), 0, accuracy: 1e-3)
        }
    }

    func testShiftLockFacesWhereTheCameraLooks() {
        for camera in stride(from: Float(-180), through: 180, by: 15) {
            let look = Quat.yaw(degrees: camera).act(Vec3(0, 0, -1))
            let body = ShiftLock.bodyYaw(walking: 123, cameraYaw: camera, turnsBody: true)
            assertClose(Facing.forward(yawDegrees: body), look)
        }
        XCTAssertEqual(ShiftLock.bodyYaw(walking: 42, cameraYaw: 90, turnsBody: false), 42)
    }

    func testShiftLockOnlyBehindThePlayer() {
        XCTAssertTrue(ShiftLock.turnsBody(isOn: true, cameraMode: .thirdPerson, photoMode: false, spectating: false))
        XCTAssertFalse(ShiftLock.turnsBody(isOn: false, cameraMode: .thirdPerson, photoMode: false, spectating: false))
        XCTAssertFalse(ShiftLock.turnsBody(isOn: true, cameraMode: .topDown, photoMode: false, spectating: false))
        XCTAssertFalse(ShiftLock.turnsBody(isOn: true, cameraMode: .thirdPerson, photoMode: true, spectating: false))
        XCTAssertFalse(ShiftLock.turnsBody(isOn: true, cameraMode: .thirdPerson, photoMode: false, spectating: true))
    }

    func testShiftLockIsKeptAndOlderSettingsStillLoad() throws {
        var hud = HUDOptions()
        XCTAssertFalse(hud.shiftLock)
        XCTAssertTrue(hud.showShiftLockButton)
        hud.shiftLock = true
        hud.showShiftLockButton = false
        let back = try JSONDecoder().decode(HUDOptions.self, from: JSONEncoder().encode(hud))
        XCTAssertTrue(back.shiftLock)
        XCTAssertFalse(back.showShiftLockButton)
        let old = try JSONDecoder().decode(HUDOptions.self, from: Data(#"{"cameraFollows":true}"#.utf8))
        XCTAssertFalse(old.shiftLock)
        XCTAssertTrue(old.showShiftLockButton)
        XCTAssertTrue(old.cameraFollows)
    }
}
