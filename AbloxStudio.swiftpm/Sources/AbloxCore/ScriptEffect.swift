import Foundation

// MARK: - Screen GUI

/// One thing a script has put on a player's screen.
///
/// A deliberately small vocabulary — text, a bar, a button — positioned by
/// anchor rather than by pixel. Scripts are written on one iPad and played on
/// every size of another; a pixel position that looked right in Studio would be
/// under the joystick on a smaller screen. Nine anchors cannot go wrong that way.
public struct HUDElement: Codable, Equatable, Hashable, Sendable, Identifiable {

    public enum Kind: Codable, Equatable, Hashable, Sendable {
        case text(String)
        /// A health bar, a timer, a capture meter.
        case bar(value: Double, maximum: Double)
        /// Tapping it calls the script's `on button(p, id)`.
        case button(String)
    }

    public enum Anchor: String, Codable, CaseIterable, Sendable {
        case topLeft = "top_left", top, topRight = "top_right"
        case left, center, right
        case bottomLeft = "bottom_left", bottom, bottomRight = "bottom_right"
    }

    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large
    }

    public var id: String
    public var kind: Kind
    public var anchor: Anchor
    public var color: ColorRGBA?
    public var size: Size

    public init(id: String, kind: Kind, anchor: Anchor = .top, color: ColorRGBA? = nil, size: Size = .medium) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.color = color
        self.size = size
    }

    public enum Limits {
        /// Per player. A HUD with more than this is unreadable on an iPad, and
        /// a script adding one element per tick would otherwise grow forever.
        public static let maximumElements = 24
        public static let maximumIDLength = 32
        public static let maximumTextLength = 120
    }
}

/// Where the camera sits.
public enum CameraMode: String, Codable, CaseIterable, Sendable {
    /// Behind and above the avatar — the default.
    case thirdPerson = "third"
    /// At the avatar's eyes, with the avatar hidden. What a shooter wants.
    case firstPerson = "first"
}

// MARK: - What scripts do to a player

/// An effect a script produced, riding on `EventAction.script` so it travels
/// the same route as every other effect — targeted or broadcast, applied on
/// the host's own screen too — without a second delivery path to keep correct.
public enum ScriptEffect: Codable, Equatable, Hashable, Sendable {
    case hud(HUDElement)
    case removeHUD(id: String)
    case clearHUD
    case camera(CameraMode)
    /// The weapon in hand, or nil for none.
    case equip(WeaponSpec?)
    case ammo(current: Int, magazine: Int, reloading: Bool)
    case health(current: Double, maximum: Double)
    /// Multipliers on walk speed and jump height.
    case movement(speed: Float, jump: Float)
    /// Shown to the shooter: the shot connected.
    case hitMarker(killed: Bool)
    /// Shown to whoever was hit.
    case damageFlash
    /// A shot's line, so everyone sees where it went.
    case tracer(from: Vec3, to: Vec3)
}
