import Foundation

// The play screen's own furniture: which chips and buttons show and how
// see-through they are, the stick's size and feel, the camera's habits, and
// the sums behind the compass and a visit's stats. Rules here; the screens
// are in UI/Game/HUDExtras.swift.

/// A button or chip in the play screen's top bar that can be put away.
public enum TopBarItem: String, Codable, CaseIterable, Sendable, Identifiable {
    case worldName, score, camera, emotes, scoreboard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .worldName: return L("World name")
        case .score: return L("Score")
        case .camera: return L("Camera button")
        case .emotes: return L("Emotes button")
        case .scoreboard: return L("Scoreboard button")
        }
    }
}

/// How big the corner map is.
public enum MapSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var points: Double {
        switch self {
        case .small: return 150
        case .medium: return 190
        case .large: return 240
        }
    }

    /// Metres across the small map shows around the player.
    public var metresAcross: Double {
        switch self {
        case .small: return 80
        case .medium: return 110
        case .large: return 150
        }
    }

    public var displayName: String {
        switch self {
        case .small: return L("Small")
        case .medium: return L("Medium")
        case .large: return L("Large")
        }
    }
}

/// Where the touch stick appears.
public enum JoystickStyle: String, Codable, CaseIterable, Sendable {
    /// Wherever the thumb lands in its half of the screen.
    case floating
    /// Always in the same corner, drawn even when not touched.
    case fixed

    public var displayName: String {
        switch self {
        case .floating: return L("Where my thumb lands")
        case .fixed: return L("Always in the corner")
        }
    }
}

/// Ready-made places and sizes for the jump button.
public enum ButtonPreset: String, CaseIterable, Sendable, Identifiable {
    case standard, big, closer, higher

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return L("Standard")
        case .big: return L("Big buttons")
        case .closer: return L("Closer to the middle")
        case .higher: return L("Higher up")
        }
    }

    private var values: (x: Double, y: Double, scale: Double, stick: Double) {
        switch self {
        case .standard: return (0, 0, 1, 1)
        case .big: return (-20, -20, 1.3, 1.25)
        case .closer: return (-90, -30, 1, 1)
        case .higher: return (0, -140, 1, 1)
        }
    }

    /// Where the preset puts the jump button (a nudge towards the middle of
    /// the screen is negative whichever side it is on), and how big the
    /// buttons and stick are.
    public func apply(to preferences: inout PlayPreferences) {
        let v = values
        preferences.jumpButtonOffset = PlayPreferences.PointOffset(x: v.x, y: v.y)
        preferences.buttonScale = v.scale
        preferences.hud.joystickScale = v.stick
        preferences.clamp()
    }

    public func matches(_ preferences: PlayPreferences) -> Bool {
        let v = values
        return preferences.jumpButtonOffset == PlayPreferences.PointOffset(x: v.x, y: v.y)
            && abs(preferences.buttonScale - v.scale) < 0.01 && abs(preferences.hud.joystickScale - v.stick) < 0.01
    }
}

/// Everything about the play screen's buttons, chips, stick and camera that
/// a player can change. One field of `PlayPreferences`, read tolerantly, so
/// an option added later never loses the others.
public struct HUDOptions: Codable, Hashable, Sendable {

    // MARK: What shows

    /// How solid the top bar, chips and buttons are.
    public var opacity: Double = 1
    public static let opacityRange: ClosedRange<Double> = 0.35...1
    public var hiddenTopBar: Set<TopBarItem> = []
    /// North, east, south and west along the top.
    public var showCompass = false
    /// Where the player stands, in metres.
    public var showPosition = false
    public var showSpeed = false
    public var showBattery = false
    /// The time of day, as on the iPad's own clock.
    public var showTimeOfDay = false
    /// Coins the score so far would bank.
    public var showCoinsPreview = false
    /// "2nd of 5" with other people in the room.
    public var showRank = true
    /// The nearest unfinished mission of the day, and how far along it is.
    public var showMissionTracker = false
    public var mapSize: MapSize = .small
    /// The map turns so the way the camera looks is up.
    public var mapTurnsWithCamera = false
    /// Buttons to zoom the camera, for anyone who cannot pinch.
    public var showZoomButtons = false
    /// A button to hold for running.
    public var showRunButton = false
    /// A button that keeps walking forward without holding the stick.
    public var showWalkButton = false
    /// A button in the top bar to switch between first and third person.
    public var showViewButton = false

    // MARK: The stick

    public var joystickStyle: JoystickStyle = .floating
    public var joystickScale: Double = 1
    public static let joystickScaleRange: ClosedRange<Double> = 0.75...1.4
    public var joystickOpacity: Double = 1
    public static let joystickOpacityRange: ClosedRange<Double> = 0.3...1
    /// How far the thumb must move before walking starts, of the stick's travel.
    public var stickDeadZone: Double = 0.06
    public static let deadZoneRange: ClosedRange<Double> = 0...0.3
    /// Only the eight main directions, for steadier walking.
    public var eightWay = false
    /// Run whenever walking, without pushing the stick all the way.
    public var alwaysRun = false

    // MARK: The camera

    /// The camera slowly swings round behind the player while they walk.
    public var cameraFollows = false
    public var invertLookX = false
    /// Up and down look speed, times left and right.
    public var verticalLookSpeed: Double = 1
    public static let verticalLookRange: ClosedRange<Double> = 0.4...1.6
    /// Two taps on the look side put the camera back behind the player.
    public var doubleTapResetsCamera = true

    // MARK: Habits

    /// A small tap felt on the jump and other on-screen buttons.
    public var buttonHaptics = true
    /// A game played alone pauses itself after three minutes untouched.
    public var pauseWhenAway = true
    /// A note when the battery is low or the iPad is hot.
    public var powerWarnings = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HUDOptions()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        opacity = read(.opacity, d.opacity)
        // Names from a newer version are skipped, not the whole set.
        let hidden = read(.hiddenTopBar, [String]())
        hiddenTopBar = Set(hidden.compactMap(TopBarItem.init(rawValue:)))
        showCompass = read(.showCompass, d.showCompass)
        showPosition = read(.showPosition, d.showPosition)
        showSpeed = read(.showSpeed, d.showSpeed)
        showBattery = read(.showBattery, d.showBattery)
        showTimeOfDay = read(.showTimeOfDay, d.showTimeOfDay)
        showCoinsPreview = read(.showCoinsPreview, d.showCoinsPreview)
        showRank = read(.showRank, d.showRank)
        showMissionTracker = read(.showMissionTracker, d.showMissionTracker)
        mapSize = read(.mapSize, d.mapSize)
        mapTurnsWithCamera = read(.mapTurnsWithCamera, d.mapTurnsWithCamera)
        showZoomButtons = read(.showZoomButtons, d.showZoomButtons)
        showRunButton = read(.showRunButton, d.showRunButton)
        showWalkButton = read(.showWalkButton, d.showWalkButton)
        showViewButton = read(.showViewButton, d.showViewButton)
        joystickStyle = read(.joystickStyle, d.joystickStyle)
        joystickScale = read(.joystickScale, d.joystickScale)
        joystickOpacity = read(.joystickOpacity, d.joystickOpacity)
        stickDeadZone = read(.stickDeadZone, d.stickDeadZone)
        eightWay = read(.eightWay, d.eightWay)
        alwaysRun = read(.alwaysRun, d.alwaysRun)
        cameraFollows = read(.cameraFollows, d.cameraFollows)
        invertLookX = read(.invertLookX, d.invertLookX)
        verticalLookSpeed = read(.verticalLookSpeed, d.verticalLookSpeed)
        doubleTapResetsCamera = read(.doubleTapResetsCamera, d.doubleTapResetsCamera)
        buttonHaptics = read(.buttonHaptics, d.buttonHaptics)
        pauseWhenAway = read(.pauseWhenAway, d.pauseWhenAway)
        powerWarnings = read(.powerWarnings, d.powerWarnings)
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(hiddenTopBar.map(\.rawValue).sorted(), forKey: .hiddenTopBar)
        try c.encode(showCompass, forKey: .showCompass)
        try c.encode(showPosition, forKey: .showPosition)
        try c.encode(showSpeed, forKey: .showSpeed)
        try c.encode(showBattery, forKey: .showBattery)
        try c.encode(showTimeOfDay, forKey: .showTimeOfDay)
        try c.encode(showCoinsPreview, forKey: .showCoinsPreview)
        try c.encode(showRank, forKey: .showRank)
        try c.encode(showMissionTracker, forKey: .showMissionTracker)
        try c.encode(mapSize, forKey: .mapSize)
        try c.encode(mapTurnsWithCamera, forKey: .mapTurnsWithCamera)
        try c.encode(showZoomButtons, forKey: .showZoomButtons)
        try c.encode(showRunButton, forKey: .showRunButton)
        try c.encode(showWalkButton, forKey: .showWalkButton)
        try c.encode(showViewButton, forKey: .showViewButton)
        try c.encode(joystickStyle, forKey: .joystickStyle)
        try c.encode(joystickScale, forKey: .joystickScale)
        try c.encode(joystickOpacity, forKey: .joystickOpacity)
        try c.encode(stickDeadZone, forKey: .stickDeadZone)
        try c.encode(eightWay, forKey: .eightWay)
        try c.encode(alwaysRun, forKey: .alwaysRun)
        try c.encode(cameraFollows, forKey: .cameraFollows)
        try c.encode(invertLookX, forKey: .invertLookX)
        try c.encode(verticalLookSpeed, forKey: .verticalLookSpeed)
        try c.encode(doubleTapResetsCamera, forKey: .doubleTapResetsCamera)
        try c.encode(buttonHaptics, forKey: .buttonHaptics)
        try c.encode(pauseWhenAway, forKey: .pauseWhenAway)
        try c.encode(powerWarnings, forKey: .powerWarnings)
    }

    private enum CodingKeys: String, CodingKey {
        case opacity, hiddenTopBar, showCompass, showPosition, showSpeed, showBattery, showTimeOfDay
        case showCoinsPreview, showRank, showMissionTracker, mapSize, mapTurnsWithCamera
        case showZoomButtons, showRunButton, showWalkButton, showViewButton
        case joystickStyle, joystickScale, joystickOpacity, stickDeadZone, eightWay, alwaysRun
        case cameraFollows, invertLookX, verticalLookSpeed, doubleTapResetsCamera
        case buttonHaptics, pauseWhenAway, powerWarnings
    }

    /// Every number back in its range.
    public mutating func clamp() {
        func within(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? Swift.min(Swift.max(value, range.lowerBound), range.upperBound) : fallback
        }
        opacity = within(opacity, Self.opacityRange, 1)
        joystickScale = within(joystickScale, Self.joystickScaleRange, 1)
        joystickOpacity = within(joystickOpacity, Self.joystickOpacityRange, 1)
        stickDeadZone = within(stickDeadZone, Self.deadZoneRange, 0.06)
        verticalLookSpeed = within(verticalLookSpeed, Self.verticalLookRange, 1)
    }

    public func shows(_ item: TopBarItem) -> Bool { !hiddenTopBar.contains(item) }

    /// Puts a top-bar item away, or back.
    public mutating func set(_ item: TopBarItem, shown: Bool) {
        if shown { hiddenTopBar.remove(item) } else { hiddenTopBar.insert(item) }
    }
}

// MARK: - The touch stick

public enum TouchStick {

    /// A touch stick's reading as the player asked for it: the dead zone
    /// taken out, bent to the eight main directions if chosen, and whether
    /// that is running. `x` right and `z` forward, never longer than 1.
    public static func shape(x: Float, z: Float, deadZone: Float, eightWay: Bool, alwaysRun: Bool,
                             runThreshold: Float = 0.85) -> (stick: Vec3, running: Bool) {
        guard x.isFinite, z.isFinite else { return (.zero, false) }
        let length = Swift.min(1, (x * x + z * z).squareRoot())
        let dead = Swift.max(0, Swift.min(0.9, deadZone.isFinite ? deadZone : 0))
        guard length > dead, length > 0 else { return (.zero, false) }
        let strength = (length - dead) / (1 - dead)
        var angle = atan2(x, z)
        if eightWay {
            let step = Float.pi / 4
            angle = (angle / step).rounded() * step
        }
        let stick = Vec3(sin(angle) * strength, 0, cos(angle) * strength)
        let running = length >= runThreshold || (alwaysRun && strength > 0.2)
        return (stick, running)
    }

    /// The stick when "keep walking" is on: the thumb's own direction while it
    /// is down, otherwise straight ahead.
    public static func keepWalking(_ stick: Vec3) -> Vec3 {
        stick == .zero ? Vec3(0, 0, 1) : stick
    }
}

// MARK: - The camera

public enum CameraHabits {

    /// How far to swing the camera this frame, in degrees, so it drifts
    /// round behind a player who is walking on. Nothing while standing
    /// still, stepping sideways (the camera would chase them round in a
    /// circle) or walking towards the camera, or when already nearly behind.
    public static func followTurn(cameraYaw: Float, bodyYaw: Float, stick: Vec3, seconds: Float, rate: Float = 1.6) -> Float {
        guard cameraYaw.isFinite, bodyYaw.isFinite, seconds.isFinite, seconds > 0 else { return 0 }
        let moving = (stick.x * stick.x + stick.z * stick.z).squareRoot()
        guard moving > 0.2, stick.z > moving * 0.5 else { return 0 }
        // Behind the body is a camera yaw of minus its facing.
        let gap = normalizeDegrees(-bodyYaw - cameraYaw)
        guard Swift.abs(gap) > 2 else { return 0 }
        return gap * (1 - exp(-rate * Swift.min(seconds, 0.1)))
    }

    /// The camera yaw that puts the camera straight behind someone facing
    /// `bodyYaw`.
    public static func behind(bodyYaw: Float) -> Float {
        normalizeDegrees(-bodyYaw)
    }

    /// A drag's look, turned by the player's choices: left-right flipped if
    /// they asked, up-down at its own speed.
    public static func look(dx: Float, dy: Float, invertX: Bool, verticalSpeed: Double) -> (dx: Float, dy: Float) {
        (invertX ? -dx : dx, dy * Float(verticalSpeed.isFinite ? verticalSpeed : 1))
    }
}

// MARK: - The compass

public enum Compass {

    /// Where the camera looks, as a bearing: 0 north (up on the map, −z), 90
    /// east (+x), in 0..<360.
    public static func bearing(cameraYaw: Float) -> Float {
        guard cameraYaw.isFinite else { return 0 }
        var degrees = (-cameraYaw).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return degrees >= 360 ? 0 : degrees
    }

    /// One mark on the compass strip.
    public struct Mark: Hashable, Sendable {
        public let bearing: Float
        public let label: String
        /// −1 (left edge) to 1 (right edge).
        public let position: Float
        public let isCardinal: Bool
    }

    static let points: [(Float, String)] = [
        (0, "N"), (45, "NE"), (90, "E"), (135, "SE"), (180, "S"), (225, "SW"), (270, "W"), (315, "NW")
    ]

    /// The letters in view on a strip `span` degrees wide.
    public static func marks(bearing: Float, span: Float = 150) -> [Mark] {
        guard span > 0 else { return [] }
        var result: [Mark] = []
        for (point, letter) in points {
            let offset = normalizeDegrees(point - bearing)
            guard Swift.abs(offset) <= span / 2 else { continue }
            result.append(Mark(bearing: point, label: localized(letter), position: offset / (span / 2),
                               isCardinal: point.truncatingRemainder(dividingBy: 90) == 0))
        }
        return result.sorted { $0.position < $1.position }
    }

    /// "North-east" and so on, for VoiceOver.
    public static func spoken(bearing: Float) -> String {
        let index = Int(((bearing.isFinite ? bearing : 0) / 45).rounded()) % 8
        switch (index + 8) % 8 {
        case 0: return L("North")
        case 1: return L("North-east")
        case 2: return L("East")
        case 3: return L("South-east")
        case 4: return L("South")
        case 5: return L("South-west")
        case 6: return L("West")
        default: return L("North-west")
        }
    }

    /// The short letters, as the player's language writes them.
    static func localized(_ letter: String) -> String {
        switch letter {
        case "N": return L("N")
        case "NE": return L("NE")
        case "E": return L("E")
        case "SE": return L("SE")
        case "S": return L("S")
        case "SW": return L("SW")
        case "W": return L("W")
        default: return L("NW")
        }
    }
}

// MARK: - A visit's stats

/// What happened on one visit to a world: how far the player walked, how
/// often they jumped, their best speed. Shown in the pause menu.
public struct VisitTally: Hashable, Sendable {
    public private(set) var metresWalked: Double = 0
    public private(set) var jumps = 0
    /// Metres a second, over the ground.
    public private(set) var topSpeed: Double = 0
    public private(set) var lastPosition: Vec3?
    private var lastTime: Double?
    private var wasGrounded = true

    /// Further than this between two readings is a teleport or a respawn,
    /// not a walk.
    public static let teleportDistance: Double = 12

    public init() {}

    /// A reading of where the player is, `time` in seconds.
    public mutating func record(position: Vec3, grounded: Bool, time: Double) {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite, time.isFinite else { return }
        defer {
            lastPosition = position
            lastTime = time
            wasGrounded = grounded
        }
        if wasGrounded && !grounded && lastPosition != nil { jumps += 1 }
        guard let last = lastPosition, let before = lastTime else { return }
        let step = Double(position.horizontalDistance(to: last))
        guard step < Self.teleportDistance else { return }
        metresWalked += step
        let seconds = time - before
        if seconds > 0.05, seconds < 2 {
            topSpeed = Swift.max(topSpeed, step / seconds)
        }
    }

    /// Forgets where the player was, after a respawn or going back to the
    /// start, so the jump is not counted as walking.
    public mutating func lostTrack() {
        lastPosition = nil
        lastTime = nil
    }
}

// MARK: - Away and power

/// Notices a game left alone: nothing touched for a while.
public struct IdleWatch: Hashable, Sendable {
    public private(set) var lastInput: Double = 0
    public static let awaySeconds: Double = 180

    public init(now: Double = 0) { lastInput = now }

    public mutating func touched(at time: Double) { lastInput = time }

    public func isAway(at time: Double, after seconds: Double = IdleWatch.awaySeconds) -> Bool {
        time - lastInput >= seconds
    }
}

public enum PowerNotice {

    /// What to say about the battery and the heat, once each per visit:
    /// low (20% or less, not charging) and hot.
    public static func message(batteryLevel: Double?, charging: Bool, heat: DeviceHeat,
                               alreadySaid: Set<String>) -> (key: String, text: String)? {
        if let level = batteryLevel, level >= 0, level <= 0.2, !charging, !alreadySaid.contains("battery") {
            return ("battery", L("Battery at {}%. Time to charge soon.", Int((level * 100).rounded())))
        }
        if heat >= .serious, !alreadySaid.contains("heat") {
            return ("heat", L("Your iPad is getting hot. The picture is made simpler to cool it down."))
        }
        return nil
    }
}

/// Places in a ranking, as words: "1st of 4".
public enum Placing {
    public static func text(place: Int, of count: Int) -> String {
        L("{}, out of {}", ordinal(place), count)
    }

    public static func ordinal(_ n: Int) -> String {
        let hundred = n % 100
        if (11...13).contains(hundred) { return L("{}th", n) }
        switch n % 10 {
        case 1: return L("{}st", n)
        case 2: return L("{}nd", n)
        case 3: return L("{}rd", n)
        default: return L("{}th", n)
        }
    }

    /// The local player's place among everyone's scores (ties share a place),
    /// or nil alone.
    public static func place(of score: Int, among scores: [Int]) -> Int? {
        guard scores.count > 1 else { return nil }
        return scores.filter { $0 > score }.count + 1
    }
}

/// Keyboard shortcuts while playing, for the list the ? key shows.
public enum PlayShortcuts {
    public static var all: [(keys: String, action: String)] {
        [
            ("W A S D", L("Walk")),
            (L("Space"), L("Jump")),
            (L("Shift"), L("Run")),
            (L("Arrow keys"), L("Look around")),
            ("F", L("Use or fire")),
            ("1 – 4", L("Favourite emotes")),
            ("T", L("Chat")),
            ("M", L("Map")),
            ("P", L("Take a picture")),
            ("V", L("First or third person")),
            ("R", L("Camera behind me")),
            ("H", L("Hide or show the buttons")),
            ("K", L("This list")),
            (L("Esc or Tab"), L("Menu"))
        ]
    }
}
