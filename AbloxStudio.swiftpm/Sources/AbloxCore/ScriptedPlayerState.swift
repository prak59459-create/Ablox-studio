import Foundation

/// What a world's script has done to *this* player, as their own iPad sees
/// it: the screen GUI, the camera, the weapon in hand, health and ammo.
///
/// Built only from `ScriptEffect`s the host sent, never from local guesses —
/// the same rule as scores. Kept out of the view layer so the folding of
/// effects into state is testable without SwiftUI.
public struct ScriptedPlayerState: Equatable, Sendable {

    public struct Health: Equatable, Sendable {
        public var current: Double
        public var maximum: Double

        public var fraction: Double {
            maximum > 0 ? Swift.min(Swift.max(current / maximum, 0), 1) : 0
        }
    }

    public struct Ammo: Equatable, Sendable {
        public var current: Int
        public var magazine: Int
        public var isReloading: Bool
    }

    /// In the order the script first showed them, so a layout does not
    /// reshuffle every time a score changes.
    public private(set) var hud: [HUDElement] = []
    public private(set) var camera: CameraMode = .thirdPerson
    public private(set) var weapon: WeaponSpec?
    public private(set) var ammo: Ammo?
    /// Nil until the script first involves health — a parkour world with a
    /// script has no health bar.
    public private(set) var health: Health?
    public private(set) var speedMultiplier: Float = 1
    public private(set) var jumpMultiplier: Float = 1
    /// Bumped per hit marker and per hit taken, so the UI can animate each
    /// one even when two arrive with the same content.
    public private(set) var hitMarkerCount = 0
    public private(set) var lastHitWasKnockout = false
    public private(set) var damageFlashCount = 0

    public init() {}

    public var isKnockedOut: Bool {
        guard let health else { return false }
        return health.current <= 0
    }

    /// Whether pressing fire now could possibly be accepted. The host checks
    /// again; this only stops the iPad sending shots it knows are pointless.
    public var canFire: Bool {
        guard weapon != nil, !isKnockedOut else { return false }
        guard let ammo else { return true }
        return !ammo.isReloading && ammo.current > 0
    }

    public func element(_ id: String) -> HUDElement? {
        hud.first { $0.id == id }
    }

    public func elements(at anchor: HUDElement.Anchor) -> [HUDElement] {
        hud.filter { $0.anchor == anchor }
    }

    public mutating func apply(_ effect: ScriptEffect) {
        switch effect {
        case let .hud(element):
            if let index = hud.firstIndex(where: { $0.id == element.id }) {
                hud[index] = element
            } else if hud.count < HUDElement.Limits.maximumElements {
                hud.append(element)
            }
        case let .removeHUD(id):
            hud.removeAll { $0.id == id }
        case .clearHUD:
            hud.removeAll()
        case let .camera(mode):
            camera = mode
        case let .equip(newWeapon):
            weapon = newWeapon
            if newWeapon == nil { ammo = nil }
        case let .ammo(current, magazine, reloading):
            ammo = Ammo(current: current, magazine: magazine, isReloading: reloading)
        case let .health(current, maximum):
            health = Health(current: current, maximum: maximum)
        case let .movement(speed, jump):
            speedMultiplier = speed
            jumpMultiplier = jump
        case let .hitMarker(killed):
            hitMarkerCount &+= 1
            lastHitWasKnockout = killed
        case .damageFlash:
            damageFlashCount &+= 1
        case .tracer:
            // Drawn by the viewport; nothing to remember.
            break
        }
    }

    public mutating func reset() {
        self = ScriptedPlayerState()
    }
}
