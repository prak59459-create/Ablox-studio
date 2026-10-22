import Foundation

/// Weapons you hit with rather than shoot (8.8): fists, a sword, a bat, an
/// axe, a knife, a spear. A suggestion said every attack looked like a gun,
/// even punching or chopping a tree.
///
/// They are ordinary weapons to the host (a short ray, the same `on hit` and
/// `on hit_block`), with three differences: no tracer line, a swing sound
/// instead of a shot, and the model in the hand is the thing itself. An iPad
/// from before 8.8 does not know the model names and draws its blaster, as it
/// did for the pistol-shaped melee weapons before.
public extension WeaponSpec {
    /// The models that are swung, not fired.
    static let meleeModels: [String] = ["fist", "sword", "bat", "axe", "knife", "spear"]

    /// Swung, not fired: no tracer and no shot sound.
    var isMelee: Bool { Self.meleeModels.contains(model) }

    /// One preset per melee model, so `p.give("fist")` works with nothing
    /// defined, and `weapon("ハンマー", {model: "bat"})` starts from a bat.
    static let meleePresets: [String: WeaponSpec] = [
        "fist": melee("fist", damage: 10, rate: 2.5, reach: 4),
        "sword": melee("sword", damage: 25, rate: 2.2, reach: 5.5),
        "bat": melee("bat", damage: 22, rate: 1.8, reach: 5),
        "axe": melee("axe", damage: 24, rate: 1.6, reach: 5),
        "knife": melee("knife", damage: 18, rate: 3, reach: 4),
        "spear": melee("spear", damage: 30, rate: 1.6, reach: 6.5)
    ]

    private static func melee(_ model: String, damage: Double, rate: Double, reach: Float) -> WeaponSpec {
        WeaponSpec(name: model, damage: damage, fireRate: rate, range: reach, magazine: 1000, reloadTime: 0, spread: 3,
                   model: model)
    }
}
