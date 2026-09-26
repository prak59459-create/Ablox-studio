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

    public struct Fade: Equatable, Sendable {
        public var color: ColorRGBA?
        public var seconds: Double
        /// Bumped per fade, so the same fade twice still animates.
        public var serial: Int
    }

    public struct Shake: Equatable, Sendable {
        public var strength: Float
        public var seconds: Double
        public var serial: Int
    }

    /// In the order the script first showed them.
    public private(set) var ui: [UIElement] = []
    public private(set) var camera: CameraSettings = .standard
    public private(set) var weapon: WeaponSpec?
    public private(set) var ammo: Ammo?
    /// Nil until the script first involves health — a parkour world with a
    /// script has no health bar.
    public private(set) var health: Health?
    public private(set) var movement: MovementScale = .normal
    public private(set) var showsControls = true
    public private(set) var showsDefaultUI = true
    public private(set) var fade = Fade(color: nil, seconds: 0, serial: 0)
    public private(set) var shake = Shake(strength: 0, seconds: 0, serial: 0)
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

    public func element(_ id: String) -> UIElement? {
        ui.first { $0.id == id }
    }

    /// The visible elements directly inside `parent` (nil: the screen),
    /// bottom layer first.
    public func children(of parent: String?) -> [UIElement] {
        ui.filter { $0.parent == parent && $0.visible }
            .enumerated()
            .sorted { $0.element.layer != $1.element.layer ? $0.element.layer < $1.element.layer : $0.offset < $1.offset }
            .map(\.element)
    }

    public mutating func apply(_ effect: ScriptEffect) {
        switch effect {
        case let .ui(element):
            if let index = ui.firstIndex(where: { $0.id == element.id }) {
                ui[index] = element
            } else if ui.count < UIElement.Limits.maximumElements {
                ui.append(element)
            }
        case let .removeUI(id):
            // Removing a panel removes what is inside it.
            var doomed: Set<String> = [id]
            var grew = true
            while grew {
                let before = doomed.count
                for element in ui where element.parent.map(doomed.contains) == true {
                    doomed.insert(element.id)
                }
                grew = doomed.count > before
            }
            ui.removeAll { doomed.contains($0.id) }
        case .clearUI:
            ui.removeAll()
        case let .camera(settings):
            camera = settings
        case let .shake(strength, seconds):
            shake = Shake(strength: strength, seconds: seconds, serial: shake.serial &+ 1)
        case let .fade(color, seconds):
            fade = Fade(color: color, seconds: seconds, serial: fade.serial &+ 1)
        case let .interface(controls, defaultUI):
            showsControls = controls
            showsDefaultUI = defaultUI
        case let .equip(newWeapon):
            weapon = newWeapon
            if newWeapon == nil { ammo = nil }
        case let .ammo(current, magazine, reloading):
            ammo = Ammo(current: current, magazine: magazine, isReloading: reloading)
        case let .health(current, maximum):
            health = Health(current: current, maximum: maximum)
        case let .movement(scale):
            movement = scale
        case .hitMarker(let killed):
            hitMarkerCount &+= 1
            lastHitWasKnockout = killed
        case .damageFlash:
            damageFlashCount &+= 1
        case .launch, .face, .tracer, .chat, .say, .store:
            // Acted on by the viewport, the chat log or the save store;
            // nothing to remember.
            break
        }
    }

    public mutating func reset() {
        self = ScriptedPlayerState()
    }
}
