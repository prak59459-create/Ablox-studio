import XCTest
@testable import AbloxCore

/// Fists, swords, axes… (8.8): swung, not fired.
final class MeleeWeaponsTests: RuntimeTestCase {

    func testEveryMeleeModelHasAPresetThatReachesShortAndNeverReloads() throws {
        for model in WeaponSpec.meleeModels {
            let spec = try XCTUnwrap(WeaponSpec.presets[model], model)
            XCTAssertTrue(spec.isMelee, model)
            XCTAssertLessThanOrEqual(spec.range, 8, model)
            XCTAssertEqual(spec.reloadTime, 0, model)
            XCTAssertEqual(spec.clamped, spec, "already in the range the host simulates: \(model)")
        }
        XCTAssertFalse(try XCTUnwrap(WeaponSpec.presets["pistol"]).isMelee)
        XCTAssertFalse(try XCTUnwrap(WeaponSpec.presets["blaster"]).isMelee)
    }

    func testAGamesOwnWeaponKeepsAMeleeModel() {
        let runtime = game(#"""
        weapon("オノ", {model: "axe", damage: 30, range: 5})
        weapon("けん", {model: "SWORD"})
        weapon("なぞ", {model: "banana"})
        """#)
        startWithBoth(runtime)
        XCTAssertEqual(runtime.weapons["オノ".lowercased()]?.model, "axe")
        XCTAssertEqual(runtime.weapons["オノ".lowercased()]?.damage, 30)
        XCTAssertEqual(runtime.weapons["けん"]?.model, "sword", "starts from the sword preset")
        XCTAssertEqual(runtime.weapons["なぞ"]?.model, "blaster", "an unknown model is still a blaster")
    }

    func testASwingDrawsNoTracerButStillHits() {
        let runtime = game(#"""
        on join(p)
          p.give("fist")
        end
        """#)
        startWithBoth(runtime)
        place(runtime, alice, at: Vec3(0, 0, -2))
        place(runtime, bob, at: .zero)
        let effects = runtime.handle(.fire(origin: Vec3(0, 1.6, -2), direction: Vec3(0, 0, 1)), from: alice, at: 1)
        let tracers = scripted(alice, effects).filter { if case .tracer = $0 { return true }; return false }
        XCTAssertTrue(tracers.isEmpty, "a punch is not a bullet")
        XCTAssertFalse(healths(bob, effects).isEmpty, "but it lands")
    }

    func testAPunchDoesNotReachAcrossTheRoom() {
        let runtime = game(#"""
        on join(p)
          p.give("fist")
        end
        """#)
        startWithBoth(runtime)
        let effects = aliceShootsBob(runtime, at: 1)
        XCTAssertTrue(healths(bob, effects).isEmpty, "ten metres is too far for a fist")
    }

    func testAShotStillDrawsItsTracer() {
        let runtime = game(#"""
        on join(p)
          p.give("pistol")
        end
        """#)
        startWithBoth(runtime)
        let effects = aliceShootsBob(runtime, at: 1)
        XCTAssertTrue(scripted(alice, effects).contains { if case .tracer = $0 { return true }; return false })
    }
}
