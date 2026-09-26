import Foundation

// How a person likes to play, beyond the controls: comfort, the eyes, the
// battery, the size of the text. Kept in the app's settings and handed to
// the play screen in one piece, so a new preference is one field here
// rather than one more parameter through every view.

public enum HapticStrength: String, Codable, CaseIterable, Sendable {
    case light, medium, strong

    public var displayName: String {
        switch self {
        case .light: return L("Light")
        case .medium: return L("Medium")
        case .strong: return L("Strong")
        }
    }
}

/// The size of the app's text.
public enum TextSize: String, Codable, CaseIterable, Sendable {
    case small, standard, large, huge

    public var displayName: String {
        switch self {
        case .small: return L("Small")
        case .standard: return L("Standard")
        case .large: return L("Large")
        case .huge: return L("Huge")
        }
    }

    /// For a script's own text, which has a fixed point size.
    public var scale: Double {
        switch self {
        case .small: return 0.88
        case .standard: return 1
        case .large: return 1.18
        case .huge: return 1.4
        }
    }
}

/// How hot the iPad is running, from `ProcessInfo.thermalState`.
public enum DeviceHeat: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public static func < (lhs: DeviceHeat, rhs: DeviceHeat) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlayPreferences: Codable, Hashable, Sendable {

    // MARK: Comfort

    /// A script's screen shake. Off for anyone it makes queasy.
    public var cameraShake = true
    /// Degrees added to (or taken from) the camera's field of view. Wider
    /// sits better with people who feel sick in games.
    public var fieldOfViewBoost: Float = 0
    public static let fieldOfViewRange: ClosedRange<Float> = -10...20

    // MARK: Feel

    public var hapticStrength: HapticStrength = .medium

    // MARK: Eyes

    /// A warm tint over the game, like Night Shift.
    public var warmScreen = false
    /// 0 (none) to 0.5: a dark veil over the game for a dim room.
    public var dimming: Double = 0
    /// Damage flashes, screen fades and shakes are softened.
    public var reduceFlashing = false
    public var textSize: TextSize = .standard

    // MARK: Battery and heat

    /// Lower quality to last longer, even when Low Power Mode is off.
    public var batterySaver = false
    /// Step the quality down by itself when the iPad gets hot.
    public var coolDownWhenHot = true

    // MARK: Play-screen extras (see the play screen)

    /// Jump by itself at the edge of a step or gap while walking.
    public var autoJump = false
    /// Every control on one side, for playing with one hand.
    public var oneHanded = false
    /// How far the third-person camera sits, times the game's own distance.
    public var cameraZoom: Float = 1
    public static let cameraZoomRange: ClosedRange<Float> = 0.5...2
    /// Where the jump button is, as a nudge from its usual place in points.
    public var jumpButtonOffset = PointOffset()
    /// The on-screen buttons' size.
    public var buttonScale: Double = 1
    public static let buttonScaleRange: ClosedRange<Double> = 0.75...1.4
    /// Effect and music volume, 0 to 1.
    public var effectsVolume: Double = 1
    public var musicVolume: Double = 0.7
    /// Ping and signal in the corner while playing.
    public var showNetworkStatus = false
    /// The small map in the corner.
    public var showMap = true
    /// How long this visit has lasted, in the top bar.
    public var showClock = false

    public struct PointOffset: Codable, Hashable, Sendable {
        public var x: Double = 0
        public var y: Double = 0
        public init(x: Double = 0, y: Double = 0) {
            self.x = x
            self.y = y
        }
    }

    public init() {}

    // Every field optional when reading, so a preference added in a later
    // version does not throw away the ones already chosen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlayPreferences.defaults
        cameraShake = try c.decodeIfPresent(Bool.self, forKey: .cameraShake) ?? d.cameraShake
        fieldOfViewBoost = try c.decodeIfPresent(Float.self, forKey: .fieldOfViewBoost) ?? d.fieldOfViewBoost
        hapticStrength = (try? c.decodeIfPresent(HapticStrength.self, forKey: .hapticStrength)) ?? d.hapticStrength
        warmScreen = try c.decodeIfPresent(Bool.self, forKey: .warmScreen) ?? d.warmScreen
        dimming = try c.decodeIfPresent(Double.self, forKey: .dimming) ?? d.dimming
        reduceFlashing = try c.decodeIfPresent(Bool.self, forKey: .reduceFlashing) ?? d.reduceFlashing
        textSize = (try? c.decodeIfPresent(TextSize.self, forKey: .textSize)) ?? d.textSize
        batterySaver = try c.decodeIfPresent(Bool.self, forKey: .batterySaver) ?? d.batterySaver
        coolDownWhenHot = try c.decodeIfPresent(Bool.self, forKey: .coolDownWhenHot) ?? d.coolDownWhenHot
        autoJump = try c.decodeIfPresent(Bool.self, forKey: .autoJump) ?? d.autoJump
        oneHanded = try c.decodeIfPresent(Bool.self, forKey: .oneHanded) ?? d.oneHanded
        cameraZoom = try c.decodeIfPresent(Float.self, forKey: .cameraZoom) ?? d.cameraZoom
        jumpButtonOffset = try c.decodeIfPresent(PointOffset.self, forKey: .jumpButtonOffset) ?? d.jumpButtonOffset
        buttonScale = try c.decodeIfPresent(Double.self, forKey: .buttonScale) ?? d.buttonScale
        effectsVolume = try c.decodeIfPresent(Double.self, forKey: .effectsVolume) ?? d.effectsVolume
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? d.musicVolume
        showNetworkStatus = try c.decodeIfPresent(Bool.self, forKey: .showNetworkStatus) ?? d.showNetworkStatus
        showMap = try c.decodeIfPresent(Bool.self, forKey: .showMap) ?? d.showMap
        showClock = try c.decodeIfPresent(Bool.self, forKey: .showClock) ?? d.showClock
        clamp()
    }

    private static let defaults = PlayPreferences()

    /// Every number back inside its range — a hand-edited or corrupt value
    /// must not make the camera sit inside the player's head.
    public mutating func clamp() {
        func within<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T { min(max(value, range.lowerBound), range.upperBound) }
        fieldOfViewBoost = fieldOfViewBoost.isFinite ? within(fieldOfViewBoost, Self.fieldOfViewRange) : 0
        dimming = dimming.isFinite ? within(dimming, 0...0.5) : 0
        cameraZoom = cameraZoom.isFinite ? within(cameraZoom, Self.cameraZoomRange) : 1
        buttonScale = buttonScale.isFinite ? within(buttonScale, Self.buttonScaleRange) : 1
        effectsVolume = effectsVolume.isFinite ? within(effectsVolume, 0...1) : 1
        musicVolume = musicVolume.isFinite ? within(musicVolume, 0...1) : 0.7
        jumpButtonOffset.x = jumpButtonOffset.x.isFinite ? within(jumpButtonOffset.x, -400...400) : 0
        jumpButtonOffset.y = jumpButtonOffset.y.isFinite ? within(jumpButtonOffset.y, -300...100) : 0
    }

    // MARK: Decisions

    /// The best graphics level allowed right now, or nil for no cap: the
    /// battery saver or Low Power Mode keep it at medium, a hot iPad at
    /// medium and a very hot one at low.
    public func graphicsCap(lowPowerMode: Bool, heat: DeviceHeat) -> GraphicsProfile.Level? {
        var cap: GraphicsProfile.Level?
        func lower(to level: GraphicsProfile.Level) {
            cap = min(cap ?? level, level)
        }
        if batterySaver || lowPowerMode { lower(to: .medium) }
        if coolDownWhenHot {
            if heat >= .critical { lower(to: .low) } else if heat >= .serious { lower(to: .medium) }
        }
        return cap
    }

    /// The field of view the camera uses, from the game's own.
    public func fieldOfView(game: Float) -> Float {
        max(10, min(150, game + fieldOfViewBoost))
    }

    /// A shake as it should be felt: none, softened, or as the game asked.
    public func shake(strength: Float) -> Float {
        guard cameraShake else { return 0 }
        return reduceFlashing ? strength * 0.4 : strength
    }
}
