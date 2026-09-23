import Foundation

// MARK: - Screen GUI

/// One thing a script has put on a player's screen: a panel, a line of text,
/// a button, an icon, a bar or a text box.
///
/// Positioned freely. `x` and `y` run from 0 to 1 across whatever holds it —
/// the screen, or a panel — so the same GUI lands in the same place on every
/// size of iPad; `pivot` says which point of the element sits there, and
/// `offset` nudges it by points. Nest elements with `parent` to build menus,
/// shops and scoreboards that move and hide as one.
public struct UIElement: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A box other elements can sit in.
        case panel
        case text
        /// Tapping it runs the script's `on button(p, id)`.
        case button
        /// An SF Symbol, named in `text`.
        case image
        /// A health bar, a timer, a capture meter.
        case bar
        /// A text box. Sending it runs `on input(p, id, text)`.
        case input
    }

    public var id: String
    public var kind: Kind
    /// The panel this sits in, or nil for the screen itself.
    public var parent: String?
    /// The words, the button label, the symbol name or the placeholder.
    public var text: String
    public var value: Double
    public var maximum: Double

    public var x: Double
    public var y: Double
    public var pivotX: Double
    public var pivotY: Double
    public var offsetX: Double
    public var offsetY: Double
    /// In points. Nil fits the content.
    public var width: Double?
    public var height: Double?

    public var color: ColorRGBA?
    public var background: ColorRGBA?
    public var fontSize: Double
    public var bold: Bool
    public var cornerRadius: Double
    public var opacity: Double
    public var visible: Bool
    /// Higher draws on top.
    public var layer: Int

    public init(
        id: String,
        kind: Kind,
        parent: String? = nil,
        text: String = "",
        value: Double = 0,
        maximum: Double = 100,
        x: Double = 0.5,
        y: Double = 0.5,
        pivotX: Double = 0.5,
        pivotY: Double = 0.5,
        offsetX: Double = 0,
        offsetY: Double = 0,
        width: Double? = nil,
        height: Double? = nil,
        color: ColorRGBA? = nil,
        background: ColorRGBA? = nil,
        fontSize: Double = 18,
        bold: Bool = false,
        cornerRadius: Double = 12,
        opacity: Double = 1,
        visible: Bool = true,
        layer: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.parent = parent
        self.text = text
        self.value = value
        self.maximum = maximum
        self.x = x
        self.y = y
        self.pivotX = pivotX
        self.pivotY = pivotY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.width = width
        self.height = height
        self.color = color
        self.background = background
        self.fontSize = fontSize
        self.bold = bold
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.visible = visible
        self.layer = layer
    }

    /// The fraction a bar is filled.
    public var fraction: Double {
        maximum > 0 ? Swift.min(Swift.max(value / maximum, 0), 1) : 0
    }

    /// Named places, for scripts that would rather say "top_left" than
    /// work out coordinates. Each sets the position and the pivot together,
    /// so the element sits inside the screen edge rather than across it.
    public static let presets: [String: (x: Double, y: Double)] = [
        "top_left": (0, 0), "top": (0.5, 0), "top_right": (1, 0),
        "left": (0, 0.5), "center": (0.5, 0.5), "right": (1, 0.5),
        "bottom_left": (0, 1), "bottom": (0.5, 1), "bottom_right": (1, 1)
    ]

    /// Places the element at a named preset, `margin` points in from the edge.
    public mutating func place(at preset: (x: Double, y: Double), margin: Double = 16) {
        x = preset.x
        y = preset.y
        pivotX = preset.x
        pivotY = preset.y
        offsetX = preset.x == 0 ? margin : preset.x == 1 ? -margin : 0
        offsetY = preset.y == 0 ? margin : preset.y == 1 ? -margin : 0
    }

    public enum Limits {
        /// Per player. Enough for a full menu screen; bounded so a script
        /// adding one element per tick cannot grow forever.
        public static let maximumElements = 300
        public static let maximumIDLength = 48
        public static let maximumTextLength = 500
    }
}

// MARK: - Camera

public struct CameraSettings: Codable, Hashable, Sendable {

    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Behind and above the avatar — the default.
        case thirdPerson = "third"
        /// At the avatar's eyes, with the avatar hidden.
        case firstPerson = "first"
        /// Looking straight down from above, for top-down games.
        case topDown = "top"
        /// Fixed in the world, looking at `target` or at the player.
        case fixed
    }

    public var mode: Mode
    /// How far behind (third person) or above (top-down), in metres.
    public var distance: Float
    public var fieldOfView: Float
    /// Where a fixed camera stands.
    public var position: Vec3?
    /// What a fixed camera looks at. Nil follows the player.
    public var target: Vec3?

    public init(mode: Mode = .thirdPerson, distance: Float = 6.5, fieldOfView: Float = 65,
                position: Vec3? = nil, target: Vec3? = nil) {
        self.mode = mode
        self.distance = distance
        self.fieldOfView = fieldOfView
        self.position = position
        self.target = target
    }

    public static let standard = CameraSettings()
}

// MARK: - Movement

/// Multipliers on how the player moves, set by a script.
public struct MovementScale: Codable, Hashable, Sendable {
    public var speed: Float
    public var jump: Float
    public var gravity: Float
    /// Cannot move or jump; can still look around.
    public var frozen: Bool

    public init(speed: Float = 1, jump: Float = 1, gravity: Float = 1, frozen: Bool = false) {
        self.speed = speed
        self.jump = jump
        self.gravity = gravity
        self.frozen = frozen
    }

    public static let normal = MovementScale()
}

// MARK: - What scripts do to a player

/// An effect a script produced, riding on `EventAction.script` so it travels
/// the same route as every other effect — targeted or broadcast, applied on
/// the host's own screen too — without a second delivery path to keep correct.
public enum ScriptEffect: Codable, Equatable, Hashable, Sendable {
    /// Adds or replaces a screen element (by id).
    case ui(UIElement)
    case removeUI(id: String)
    case clearUI
    case camera(CameraSettings)
    case shake(strength: Float, seconds: Double)
    /// Covers the screen in a colour, fading over `seconds`. Nil fades back.
    case fade(color: ColorRGBA?, seconds: Double)
    /// Whether the joystick and buttons, and the top bar and chat, show.
    case interface(controls: Bool, defaultUI: Bool)
    /// The weapon in hand, or nil for none.
    case equip(WeaponSpec?)
    case ammo(current: Int, magazine: Int, reloading: Bool)
    case health(current: Double, maximum: Double)
    case movement(MovementScale)
    /// Sets the player's velocity: a jump pad, a knock-back, a cannon.
    case launch(Vec3)
    /// Turns the player (and their camera) to face this way.
    case face(yawDegrees: Float)
    /// Shown to the shooter: the shot connected.
    case hitMarker(killed: Bool)
    /// Shown to whoever was hit.
    case damageFlash
    /// A shot's line, so everyone sees where it went.
    case tracer(from: Vec3, to: Vec3)
    /// A line in the chat, from the game rather than a person.
    case chat(String)
}
