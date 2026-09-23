import XCTest
@testable import AbloxCore

/// Shots are resolved on the host, so these are the rules every argument in a
/// 1v1 gets settled by.
final class CombatTests: XCTestCase {

    private let shooter = PeerID()
    private let target = PeerID()
    private let other = PeerID()

    private let eyes = Vec3(0, PlayerHitBody.eyeHeight, -10)
    private let ahead = Vec3(0, 0, 1)

    // MARK: Hitscan

    func testAShotStraightAtSomeoneHitsThem() {
        // Chest height: the straight part of the capsule.
        let result = Hitscan.cast(from: Vec3(0, 1, -10), direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .player(target))
        XCTAssertEqual(result.distance, 10 - PlayerHitBody.radius, accuracy: 0.001)
    }

    func testEyeLevelMeetsTheRoundedHead() {
        // At 1.6 m the head has curved in, so the hit is a little further
        // away than the body's radius: the capsule really is round.
        let result = Hitscan.cast(from: eyes, direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .player(target))
        XCTAssertGreaterThan(result.distance, 10 - PlayerHitBody.radius)
        XCTAssertLessThan(result.distance, 10)
    }

    func testAShotPastTheShoulderMisses() {
        // A box would count this: its corners stick out past the capsule.
        let result = Hitscan.cast(from: Vec3(0.45, 1.0, -10), direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .nothing)
    }

    func testAShotOverTheHeadMisses() {
        let result = Hitscan.cast(from: Vec3(0, 1.95, -10), direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .nothing)
    }

    func testTheTopOfTheHeadCounts() {
        let result = Hitscan.cast(from: Vec3(0, 1.75, -10), direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .player(target))
    }

    func testAShotFromAboveHitsTheHead() {
        let result = Hitscan.cast(from: Vec3(0, 10, 0), direction: Vec3(0, -1, 0), range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .player(target))
        XCTAssertEqual(result.point.y, PlayerHitBody.height, accuracy: 0.001)
    }

    func testWallsStopShots() {
        let wall = UUID()
        let result = Hitscan.cast(from: eyes, direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)],
                                  blocks: [(wall, BoundingBox(center: Vec3(0, 1, -5), size: Vec3(4, 4, 0.5)))])
        XCTAssertEqual(result.target, .block(wall), "cover has to work")
    }

    func testAWallBehindTheTargetDoesNotProtectThem() {
        let wall = UUID()
        let result = Hitscan.cast(from: eyes, direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, .zero)],
                                  blocks: [(wall, BoundingBox(center: Vec3(0, 1, 5), size: Vec3(4, 4, 0.5)))])
        XCTAssertEqual(result.target, .player(target))
    }

    func testTheNearestPlayerTakesTheShot() {
        let result = Hitscan.cast(from: eyes, direction: ahead, range: 60, shooter: shooter,
                                  players: [(target, Vec3(0, 0, 5)), (other, .zero)], blocks: [])
        XCTAssertEqual(result.target, .player(other))
    }

    func testYouCannotShootYourself() {
        let result = Hitscan.cast(from: Vec3(0, 1.6, 0), direction: ahead, range: 60, shooter: shooter,
                                  players: [(shooter, .zero)], blocks: [])
        XCTAssertEqual(result.target, .nothing)
    }

    func testRangeIsRespected() {
        let result = Hitscan.cast(from: eyes, direction: ahead, range: 5, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .nothing)
        XCTAssertEqual(result.point.z, eyes.z + 5, accuracy: 0.001, "a miss ends at the weapon's range")
    }

    func testAZeroDirectionHitsNothing() {
        let result = Hitscan.cast(from: eyes, direction: .zero, range: 60, shooter: shooter,
                                  players: [(target, .zero)], blocks: [])
        XCTAssertEqual(result.target, .nothing)
    }

    func testSpreadStaysInsideItsCone() {
        var random = ScriptRandom(seed: 7)
        for _ in 0..<200 {
            let direction = Hitscan.spread(ahead, degrees: 5, random: &random)
            let angle = acos(Swift.min(1, direction.dot(ahead))) * 180 / .pi
            XCTAssertLessThanOrEqual(angle, 5 * 1.5, "yaw and pitch of 5° each stay within ~7°")
            XCTAssertEqual(direction.length, 1, accuracy: 0.001)
        }
    }

    func testNoSpreadIsALaser() {
        var random = ScriptRandom(seed: 7)
        XCTAssertEqual(Hitscan.spread(ahead, degrees: 0, random: &random), ahead)
    }

    // MARK: Weapons

    func testAbsurdWeaponsAreClamped() {
        let silly = WeaponSpec(name: String(repeating: "x", count: 100), damage: -5, fireRate: 1_000_000,
                               range: 50_000, magazine: 0, reloadTime: 999, spread: 400).clamped
        XCTAssertEqual(silly.name.count, 32)
        XCTAssertEqual(silly.damage, 0)
        XCTAssertEqual(silly.fireRate, 30)
        XCTAssertEqual(silly.range, 1_000)
        XCTAssertEqual(silly.magazine, 1)
        XCTAssertEqual(silly.reloadTime, 60)
        XCTAssertEqual(silly.spread, 45)
        XCTAssertEqual(WeaponSpec(name: "x", damage: .infinity).clamped.damage, 0, "not a number is not a weapon")
    }

    func testEveryPresetIsAlreadyWithinLimits() {
        for (name, weapon) in WeaponSpec.presets {
            XCTAssertEqual(weapon, weapon.clamped, "\(name) should not need clamping")
            XCTAssertEqual(weapon.name, name)
        }
    }

    // MARK: Checking shots

    private func armed(_ weapon: WeaponSpec = WeaponSpec(name: "test", fireRate: 2, magazine: 3, reloadTime: 1)) -> ArmedState {
        ArmedState(weapon: weapon)
    }

    func testAnHonestShotIsAccepted() {
        let state = armed()
        XCTAssertNil(state.refusal(at: 0, origin: Vec3(0, 1.6, 0), direction: ahead, shooterFeet: .zero))
    }

    func testFiringFasterThanTheWeaponIsRefused() {
        var state = armed()
        state.shoot(at: 0)
        XCTAssertEqual(state.refusal(at: 0.1, origin: Vec3(0, 1.6, 0), direction: ahead, shooterFeet: .zero), .tooSoon)
        XCTAssertNil(state.refusal(at: 0.5, origin: Vec3(0, 1.6, 0), direction: ahead, shooterFeet: .zero))
    }

    func testNetworkJitterIsForgiven() {
        // Two shots sent 0.5 s apart can arrive 0.4 s apart.
        var state = armed()
        state.shoot(at: 0)
        XCTAssertNil(state.refusal(at: 0.4, origin: Vec3(0, 1.6, 0), direction: ahead, shooterFeet: .zero))
    }

    func testShootingFromAcrossTheMapIsRefused() {
        let state = armed()
        XCTAssertEqual(state.refusal(at: 0, origin: Vec3(30, 1.6, 0), direction: ahead, shooterFeet: .zero), .tooFarFromBody)
    }

    func testANonsenseDirectionIsRefused() {
        let state = armed()
        XCTAssertEqual(state.refusal(at: 0, origin: Vec3(0, 1.6, 0), direction: .zero, shooterFeet: .zero), .badDirection)
        XCTAssertEqual(state.refusal(at: 0, origin: Vec3(0, 1.6, 0), direction: Vec3(.nan, 0, 1), shooterFeet: .zero), .badDirection)
    }

    func testTheLastRoundStartsAReload() {
        var state = armed()
        state.shoot(at: 0)
        state.shoot(at: 1)
        XCTAssertFalse(state.isReloading)
        state.shoot(at: 2)
        XCTAssertEqual(state.ammo, 0)
        XCTAssertTrue(state.isReloading)
        XCTAssertEqual(state.refusal(at: 2.6, origin: Vec3(0, 1.6, 0), direction: ahead, shooterFeet: .zero), .reloading)

        XCTAssertFalse(state.advance(to: 2.5))
        XCTAssertTrue(state.advance(to: 3))
        XCTAssertEqual(state.ammo, 3)
        XCTAssertFalse(state.isReloading)
    }

    func testReloadingEarly() {
        var state = armed()
        XCTAssertFalse(state.startReload(at: 0), "a full magazine has nothing to reload")
        state.shoot(at: 0)
        XCTAssertTrue(state.startReload(at: 0.1))
        XCTAssertFalse(state.startReload(at: 0.2), "already reloading")
        state.advance(to: 1.1)
        XCTAssertEqual(state.ammo, 3)
    }
}
