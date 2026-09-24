import Foundation

/// What the player picks in Settings → Graphics.
public enum GraphicsQuality: String, Codable, CaseIterable, Sendable {
    /// Starts high and steps down on its own to stay above 30 fps.
    case auto
    case high
    case medium
    case low

    public var displayName: String {
        switch self {
        case .auto: return L("Auto")
        case .high: return L("High")
        case .medium: return L("Medium")
        case .low: return L("Low")
        }
    }

    public var detail: String {
        switch self {
        case .auto: return L("Lowers the quality by itself when the game gets slow, to stay above 30 fps.")
        case .high: return L("Shadows, smooth shapes and everything in view. For newer iPads.")
        case .medium: return L("Shorter shadows, simpler shapes and a slightly lower resolution.")
        case .low: return L("No shadows, simple shapes, far parts hidden and a lower resolution. For big worlds and older iPads.")
        }
    }

    /// The fixed level, or nil for `auto`.
    public var fixedLevel: GraphicsProfile.Level? {
        switch self {
        case .auto: return nil
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }
}

/// What the renderer does at one quality level. Plain numbers, so the choice
/// of what each level trades away is written down in one testable place.
public struct GraphicsProfile: Equatable, Sendable {

    public enum Level: Int, Comparable, CaseIterable, Sendable {
        case low = 0, medium, high

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var lower: Level? { Level(rawValue: rawValue - 1) }
        public var higher: Level? { Level(rawValue: rawValue + 1) }

        public var displayName: String {
            switch self {
            case .high: return L("High")
            case .medium: return L("Medium")
            case .low: return L("Low")
            }
        }
    }

    public var level: Level
    /// How far the sun's shadows reach, in metres. Nil: no shadows at all —
    /// the shadow pass draws the whole world a second time.
    public var shadowDistance: Float?
    /// The fraction of the screen's full resolution drawn. The iPad's screen
    /// has more pixels than a block game needs to look sharp.
    public var resolutionScale: Float
    /// Parts further than this from the camera are not drawn. Nil: all of them.
    /// Big parts (the ground, a building's walls) are measured to their
    /// nearest edge, so they never pop out while you are next to them.
    public var viewDistance: Float?
    /// Rounded box edges and many-sided spheres and cylinders.
    public var smoothShapes: Bool
    /// Sides on a cylinder or cone, bands on a sphere.
    public var roundSegments: Int
    public var sphereRings: Int
    /// HDR, soft contact shadows and depth of field.
    public var postEffects: Bool

    public static func profile(for level: Level) -> GraphicsProfile {
        switch level {
        case .high:
            return GraphicsProfile(level: .high, shadowDistance: 40, resolutionScale: 1, viewDistance: nil,
                                   smoothShapes: true, roundSegments: 24, sphereRings: 16, postEffects: true)
        case .medium:
            return GraphicsProfile(level: .medium, shadowDistance: 20, resolutionScale: 0.85, viewDistance: 140,
                                   smoothShapes: false, roundSegments: 16, sphereRings: 10, postEffects: true)
        case .low:
            return GraphicsProfile(level: .low, shadowDistance: nil, resolutionScale: 0.7, viewDistance: 80,
                                   smoothShapes: false, roundSegments: 10, sphereRings: 6, postEffects: false)
        }
    }
}

/// Watches how long frames take and moves between quality levels so the
/// game stays above 30 fps, without flickering between two levels.
///
/// Frame times are gathered into one-second windows. Two slow windows in a
/// row step down straight away — a stutter is what people notice. Stepping
/// back up waits for a long run of fast windows, and never goes back to a
/// level that was too slow in the last minute.
public struct FrameRateGovernor: Sendable {

    public private(set) var level: GraphicsProfile.Level
    /// Frames per second over the last full window, for the on-screen counter.
    public private(set) var framesPerSecond: Double = 0

    public static let minimumFPS: Double = 30
    /// Below this, a window counts as slow. A little under 30, so a game
    /// that sits at exactly 30 is not pushed around by rounding.
    static let slowFPS: Double = 28
    /// At or above this, a window counts as having room to spare.
    static let fastFPS: Double = 55
    static let slowWindowsToStepDown = 2
    static let fastWindowsToStepUp = 10
    static let noReturnSeconds: Double = 60

    private var clock: Double = 0
    private var windowTime: Double = 0
    private var windowFrames = 0
    private var slowWindows = 0
    private var fastWindows = 0
    /// When each level was last found too slow.
    private var tooSlowAt: [GraphicsProfile.Level: Double] = [:]

    public init(startingAt level: GraphicsProfile.Level = .high) {
        self.level = level
    }

    /// Adds one frame. Returns the new level when it changes.
    public mutating func record(frameTime: Double) -> GraphicsProfile.Level? {
        guard frameTime.isFinite, frameTime > 0 else { return nil }
        // A frame over half a second is a pause (the app was in the
        // background, a sheet opened), not the game being slow.
        guard frameTime < 0.5 else { return nil }

        clock += frameTime
        windowTime += frameTime
        windowFrames += 1
        guard windowTime >= 1 else { return nil }

        framesPerSecond = Double(windowFrames) / windowTime
        windowTime = 0
        windowFrames = 0

        if framesPerSecond < Self.slowFPS {
            slowWindows += 1
            fastWindows = 0
        } else if framesPerSecond >= Self.fastFPS {
            fastWindows += 1
            slowWindows = 0
        } else {
            slowWindows = 0
            fastWindows = 0
        }

        if slowWindows >= Self.slowWindowsToStepDown, let lower = level.lower {
            tooSlowAt[level] = clock
            level = lower
            slowWindows = 0
            fastWindows = 0
            return level
        }

        if fastWindows >= Self.fastWindowsToStepUp, let higher = level.higher {
            fastWindows = 0
            if let when = tooSlowAt[higher], clock - when < Self.noReturnSeconds { return nil }
            level = higher
            return level
        }
        return nil
    }
}
