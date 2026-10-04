import Foundation

// What a world can look, sound and behave like beyond its blocks: weather,
// the time of day and the sky, a screen look, particles, pictures on blocks,
// sounds and music made from nothing but numbers, the arrow that points the
// way, a player's things, conversations, shops, countdowns, leaderboards,
// platforms that move by themselves, and swimming and climbing.
//
// All plain data and arithmetic, so it is tested here; `Engine` draws and
// plays it.

// MARK: - Weather and sky

public enum Weather: String, Codable, CaseIterable, Sendable {
    case clear, rain, snow, fog, storm

    public var displayName: String {
        switch self {
        case .clear: return L("Clear")
        case .rain: return L("Rain")
        case .snow: return L("Snow")
        case .fog: return L("Fog")
        case .storm: return L("Storm")
        }
    }

    /// What falls from the sky, if anything.
    public var falling: ParticleKind? {
        switch self {
        case .rain, .storm: return .rain
        case .snow: return .snow
        case .clear, .fog: return nil
        }
    }

    /// How much the distance fades into the sky colour, 0 to 1.
    public var haze: Float {
        switch self {
        case .clear: return 0
        case .rain: return 0.18
        case .snow: return 0.22
        case .fog: return 0.6
        case .storm: return 0.3
        }
    }

    /// How much darker the day is under the clouds.
    public var gloom: Float {
        switch self {
        case .clear, .snow: return 0
        case .rain, .fog: return 0.2
        case .storm: return 0.45
        }
    }
}

public enum SkyStyle: String, Codable, CaseIterable, Sendable {
    case gradient, clouds, sunset, stars, aurora, space

    public var displayName: String {
        switch self {
        case .gradient: return L("Plain")
        case .clouds: return L("Clouds")
        case .sunset: return L("Sunset")
        case .stars: return L("Stars")
        case .aurora: return L("Aurora")
        case .space: return L("Space")
        }
    }
}

/// A look for the whole screen.
public enum ScreenEffect: String, Codable, CaseIterable, Sendable {
    case none, bloom, vivid, warm, cool, noir, retro, dream

    public var displayName: String {
        switch self {
        case .none: return L("None")
        case .bloom: return L("Glow")
        case .vivid: return L("Vivid")
        case .warm: return L("Warm")
        case .cool: return L("Cool")
        case .noir: return L("Black and white")
        case .retro: return L("Retro")
        case .dream: return L("Dreamy")
        }
    }
}

/// The time of day, and what it does to the sun, the light and the sky.
public enum DayCycle {

    /// The hour now (0 to 24), starting from `start` and moving a whole day
    /// every `dayLengthMinutes`. A day length of 0 stands still.
    public static func hour(start: Float, dayLengthMinutes: Float, elapsed: Double) -> Float {
        guard dayLengthMinutes > 0, elapsed.isFinite else { return wrap(start) }
        let hours = Float(elapsed / 60) / dayLengthMinutes * 24
        return wrap(start + hours)
    }

    static func wrap(_ hour: Float) -> Float {
        guard hour.isFinite else { return 12 }
        let wrapped = hour.truncatingRemainder(dividingBy: 24)
        return wrapped < 0 ? wrapped + 24 : wrapped
    }

    /// How high the sun is, 0 (set) to 1 (noon); negative at night.
    public static func sunHeight(hour: Float) -> Float {
        cos((wrap(hour) - 12) / 12 * .pi)
    }

    /// The sun's pitch in degrees, as `EnvironmentSettings.sunPitchDegrees`
    /// takes it: straight down at noon, level at six. At night the light
    /// comes from the moon instead, opposite.
    public static func sunPitch(hour: Float) -> Float {
        let height = sunHeight(hour: hour)
        let angle = asin(Swift.max(-1, Swift.min(1, abs(height)))) * 180 / .pi
        return -Swift.max(8, angle)
    }

    /// The sun's direction round the sky: rising in the east, setting west.
    public static func sunYaw(hour: Float) -> Float {
        wrap(hour) / 24 * 360 - 90
    }

    /// How bright it is, 0.25 (night) to 1 (day).
    public static func light(hour: Float) -> Float {
        let height = sunHeight(hour: hour)
        return 0.25 + 0.75 * Swift.max(0, Swift.min(1, height * 2.2 + 0.25))
    }

    public static func isNight(hour: Float) -> Bool {
        sunHeight(hour: hour) < -0.1
    }

    /// The sky's colours at `hour`, starting from the world's own.
    public static func sky(hour: Float, top: ColorRGBA, bottom: ColorRGBA) -> (top: ColorRGBA, bottom: ColorRGBA) {
        let height = sunHeight(hour: hour)
        let night = (top: ColorRGBA(r: 0.02, g: 0.03, b: 0.09), bottom: ColorRGBA(r: 0.05, g: 0.07, b: 0.16))
        let dusk = (top: ColorRGBA(r: 0.23, g: 0.2, b: 0.45), bottom: ColorRGBA(r: 0.98, g: 0.55, b: 0.3))
        if height >= 0.35 { return (top, bottom) }
        if height >= 0 {
            // Toward sunset colours as the sun comes down.
            let t = 1 - height / 0.35
            return (top.mixed(with: dusk.top, amount: t * 0.8), bottom.mixed(with: dusk.bottom, amount: t * 0.85))
        }
        // Dusk into night.
        let t = Swift.min(1, -height / 0.3)
        return (dusk.top.mixed(with: night.top, amount: t), dusk.bottom.mixed(with: night.bottom, amount: t))
    }
}

// MARK: - Particles

public enum ParticleKind: String, Codable, CaseIterable, Sendable, ComparedByCase {
    case fire, smoke, sparkles, confetti, rain, snow, bubbles, hearts, stars, leaves, magic, dust

    public var displayName: String {
        switch self {
        case .fire: return L("Fire")
        case .smoke: return L("Smoke")
        case .sparkles: return L("Sparkles")
        case .confetti: return L("Confetti")
        case .rain: return L("Rain")
        case .snow: return L("Snow")
        case .bubbles: return L("Bubbles")
        case .hearts: return L("Hearts")
        case .stars: return L("Stars")
        case .leaves: return L("Leaves")
        case .magic: return L("Magic")
        case .dust: return L("Dust")
        }
    }

    /// How the bits look and move.
    public var spec: ParticleSpec {
        func hex(_ value: String) -> ColorRGBA { ColorRGBA(hex: value) ?? ColorRGBA(r: 1, g: 1, b: 1) }
        switch self {
        case .fire:
            return ParticleSpec(colors: [hex("#FDE047"), hex("#FB923C"), hex("#EF4444")], rate: 40, lifetime: 0.4...0.9,
                                speed: 1.2, spread: 25, upward: 2.2, gravity: 1.5, size: 0.22, shrinks: true, glows: true)
        case .smoke:
            return ParticleSpec(colors: [hex("#9CA3AF"), hex("#6B7280")], rate: 14, lifetime: 1.4...2.6,
                                speed: 0.5, spread: 30, upward: 1.1, gravity: 0.3, size: 0.45, shrinks: false, glows: false)
        case .sparkles:
            return ParticleSpec(colors: [hex("#FEF08A"), hex("#FFFFFF"), hex("#A5F3FC")], rate: 24, lifetime: 0.5...1.1,
                                speed: 1.6, spread: 180, upward: 0.4, gravity: -0.5, size: 0.1, shrinks: true, glows: true)
        case .confetti:
            return ParticleSpec(colors: [hex("#F43F5E"), hex("#22D3EE"), hex("#FACC15"), hex("#A855F7"), hex("#4ADE80")],
                                rate: 60, lifetime: 1.6...2.6, speed: 5, spread: 55, upward: 5, gravity: -7, size: 0.12,
                                shrinks: false, glows: false)
        case .rain:
            return ParticleSpec(colors: [hex("#93C5FD")], rate: 220, lifetime: 0.7...1.0,
                                speed: 0.2, spread: 5, upward: -16, gravity: -4, size: 0.05, shrinks: false, glows: false)
        case .snow:
            return ParticleSpec(colors: [hex("#FFFFFF"), hex("#E0F2FE")], rate: 90, lifetime: 3...5,
                                speed: 0.5, spread: 180, upward: -1.3, gravity: 0, size: 0.1, shrinks: false, glows: true)
        case .bubbles:
            return ParticleSpec(colors: [hex("#BAE6FD"), hex("#E0F2FE")], rate: 12, lifetime: 1.5...3,
                                speed: 0.4, spread: 40, upward: 1.2, gravity: 0.2, size: 0.18, shrinks: false, glows: false)
        case .hearts:
            return ParticleSpec(colors: [hex("#F472B6"), hex("#FB7185")], rate: 10, lifetime: 1.2...2,
                                speed: 0.6, spread: 50, upward: 1.4, gravity: 0.2, size: 0.2, shrinks: true, glows: true)
        case .stars:
            return ParticleSpec(colors: [hex("#FDE047"), hex("#FFFFFF")], rate: 18, lifetime: 0.8...1.5,
                                speed: 2.2, spread: 180, upward: 1, gravity: -2, size: 0.16, shrinks: true, glows: true)
        case .leaves:
            return ParticleSpec(colors: [hex("#84CC16"), hex("#F59E0B"), hex("#EA580C")], rate: 8, lifetime: 3...5,
                                speed: 0.8, spread: 180, upward: -0.9, gravity: 0, size: 0.18, shrinks: false, glows: false)
        case .magic:
            return ParticleSpec(colors: [hex("#C084FC"), hex("#818CF8"), hex("#F0ABFC")], rate: 30, lifetime: 0.7...1.4,
                                speed: 1, spread: 180, upward: 1.2, gravity: 0.5, size: 0.12, shrinks: true, glows: true)
        case .dust:
            return ParticleSpec(colors: [hex("#D6D3D1"), hex("#A8A29E")], rate: 16, lifetime: 0.6...1.2,
                                speed: 1.4, spread: 70, upward: 0.4, gravity: -1, size: 0.14, shrinks: true, glows: false)
        }
    }
}

public struct ParticleSpec: Hashable, Sendable {
    public var colors: [ColorRGBA]
    /// Bits a second from a block that keeps giving them off.
    public var rate: Float
    public var lifetime: ClosedRange<Float>
    /// How fast they fly off, and in how wide a cone (degrees; 180 is all
    /// ways).
    public var speed: Float
    public var spread: Float
    /// Straight up at the start (negative falls).
    public var upward: Float
    /// Added to the upward speed every second (negative pulls down).
    public var gravity: Float
    public var size: Float
    public var shrinks: Bool
    /// Drawn as light, not lit.
    public var glows: Bool
}

/// Some bits all at once, or for a few seconds, at a place.
public struct ParticleBurst: Codable, Hashable, Sendable {
    public static let maximumAmount = 200
    public static let maximumSeconds: Double = 30

    public var kind: ParticleKind
    public var position: Vec3
    /// How many at once (a puff), or a second for `seconds`.
    public var amount: Int
    /// 0 for one puff.
    public var seconds: Double
    public var color: ColorRGBA?

    public init(kind: ParticleKind, position: Vec3, amount: Int = 30, seconds: Double = 0, color: ColorRGBA? = nil) {
        self.kind = kind
        self.position = position
        self.amount = Swift.max(1, Swift.min(Self.maximumAmount, amount))
        self.seconds = Swift.max(0, Swift.min(Self.maximumSeconds, seconds.isFinite ? seconds : 0))
        self.color = color
    }
}

// MARK: - Pictures on blocks

/// A picture kept in the world file, shown on blocks that name it.
public struct WorldImage: Codable, Hashable, Sendable, Identifiable {
    /// Twelve of a quarter of a megabyte: with the blocks, still well inside
    /// one packet (`AbloxProtocol.maxPayloadLength`) when the world is sent.
    public static let maximumCount = 12
    public static let maximumBytes = 250_000

    public var id: UUID
    public var name: String
    /// PNG or JPEG.
    public var data: Data

    public init(id: UUID = UUID(), name: String, data: Data) {
        self.id = id
        self.name = String(name.prefix(60))
        self.data = data
    }

    /// Small enough to send to everyone, and looks like a picture.
    public var isAcceptable: Bool {
        guard data.count <= Self.maximumBytes, data.count > 8 else { return false }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let head = [UInt8](data.prefix(4))
        return head.starts(with: png) || head.starts(with: jpeg)
    }
}

// MARK: - Sounds made from numbers

/// One tone of a sound effect: a pitch sliding from `frequency` to
/// `endFrequency` over `duration`.
public struct ToneStep: Hashable, Sendable {
    public enum Wave: String, Sendable { case sine, square, triangle, saw, noise }

    public var frequency: Float
    public var endFrequency: Float
    public var duration: Float
    public var wave: Wave
    public var volume: Float

    public init(_ frequency: Float, to endFrequency: Float? = nil, _ duration: Float, _ wave: Wave = .square, volume: Float = 0.5) {
        self.frequency = frequency
        self.endFrequency = endFrequency ?? frequency
        self.duration = duration
        self.wave = wave
        self.volume = volume
    }
}

public extension SoundCue {
    /// The tones this cue is made of, one after another.
    var tones: [ToneStep] {
        switch self {
        case .collect, .coin: return [ToneStep(988, 0.06), ToneStep(1319, 0.14)]
        case .checkpoint: return [ToneStep(523, 0.09, .triangle), ToneStep(659, 0.09, .triangle), ToneStep(784, 0.2, .triangle)]
        case .hurt: return [ToneStep(300, to: 120, 0.22, .saw, volume: 0.45)]
        case .bounce: return [ToneStep(220, to: 660, 0.18, .sine, volume: 0.6)]
        case .teleport: return [ToneStep(300, to: 1400, 0.3, .sine, volume: 0.4)]
        case .goal, .win:
            return [ToneStep(523, 0.12, .square), ToneStep(659, 0.12, .square), ToneStep(784, 0.12, .square),
                    ToneStep(1047, 0.35, .square)]
        case .join: return [ToneStep(660, 0.08, .triangle), ToneStep(880, 0.12, .triangle)]
        case .leave: return [ToneStep(880, 0.08, .triangle), ToneStep(660, 0.12, .triangle)]
        case .tick: return [ToneStep(1600, 0.03, .square, volume: 0.25)]
        case .error: return [ToneStep(200, 0.12, .square), ToneStep(150, 0.18, .square)]
        case .shoot, .laser: return [ToneStep(1800, to: 300, 0.12, .square, volume: 0.35)]
        case .hit: return [ToneStep(150, to: 80, 0.08, .noise, volume: 0.5)]
        case .reload: return [ToneStep(400, 0.04, .noise, volume: 0.3), ToneStep(700, 0.05, .noise, volume: 0.3)]
        case .defeat, .lose:
            return [ToneStep(392, 0.18, .triangle), ToneStep(330, 0.18, .triangle), ToneStep(262, 0.4, .triangle)]
        case .jump: return [ToneStep(330, to: 700, 0.12, .square, volume: 0.35)]
        case .powerUp:
            return [ToneStep(392, 0.07), ToneStep(523, 0.07), ToneStep(659, 0.07), ToneStep(784, 0.07), ToneStep(1047, 0.2)]
        case .explosion: return [ToneStep(120, to: 40, 0.6, .noise, volume: 0.8)]
        case .splash: return [ToneStep(900, to: 200, 0.35, .noise, volume: 0.45)]
        case .door: return [ToneStep(180, to: 140, 0.25, .saw, volume: 0.3)]
        case .click: return [ToneStep(1200, 0.02, .square, volume: 0.3)]
        case .whoosh: return [ToneStep(300, to: 1200, 0.3, .noise, volume: 0.35)]
        case .magic: return [ToneStep(784, 0.06, .sine), ToneStep(988, 0.06, .sine), ToneStep(1319, 0.06, .sine), ToneStep(1760, 0.25, .sine)]
        case .pop: return [ToneStep(500, to: 1100, 0.06, .sine, volume: 0.6)]
        case .bell: return [ToneStep(1319, 0.6, .sine, volume: 0.5)]
        case .alarm: return [ToneStep(880, 0.15), ToneStep(660, 0.15), ToneStep(880, 0.15), ToneStep(660, 0.15)]
        case .drum: return [ToneStep(90, to: 50, 0.18, .sine, volume: 0.9)]
        }
    }
}

/// A sound a script asked for, louder or softer, higher or lower.
public struct SoundPlay: Codable, Hashable, Sendable {
    public var name: String
    public var volume: Float
    public var pitch: Float

    public init(name: String, volume: Float = 1, pitch: Float = 1) {
        self.name = name
        self.volume = Swift.max(0, Swift.min(1, volume.isFinite ? volume : 1))
        self.pitch = Swift.max(0.25, Swift.min(4, pitch.isFinite ? pitch : 1))
    }
}

// MARK: - Music made from numbers

public enum MusicTrack: String, Codable, CaseIterable, Sendable {
    case calm, adventure, spooky, race, boss, shop, party, space

    public var displayName: String {
        switch self {
        case .calm: return L("Calm")
        case .adventure: return L("Adventure")
        case .spooky: return L("Spooky")
        case .race: return L("Race")
        case .boss: return L("Boss battle")
        case .shop: return L("Shop")
        case .party: return L("Party")
        case .space: return L("Space")
        }
    }

    /// Beats a minute.
    public var tempo: Double {
        switch self {
        case .calm: return 84
        case .adventure: return 118
        case .spooky: return 72
        case .race: return 150
        case .boss: return 140
        case .shop: return 104
        case .party: return 124
        case .space: return 90
        }
    }

    /// The key, as a MIDI note, and the scale's steps.
    var root: Int {
        switch self {
        case .calm: return 60
        case .adventure: return 62
        case .spooky: return 57
        case .race: return 64
        case .boss: return 52
        case .shop: return 65
        case .party: return 60
        case .space: return 55
        }
    }

    var scale: [Int] {
        switch self {
        case .calm, .shop, .party, .adventure, .race: return [0, 2, 4, 7, 9]      // major pentatonic
        case .spooky, .boss: return [0, 2, 3, 5, 7, 8, 11]                       // harmonic minor
        case .space: return [0, 2, 4, 6, 7, 9, 11]                               // lydian
        }
    }

    /// Chords, as scale degrees, one a bar.
    var progression: [Int] {
        switch self {
        case .calm: return [0, 3, 4, 2]
        case .adventure: return [0, 4, 3, 4]
        case .spooky: return [0, 0, 5, 4]
        case .race: return [0, 3, 0, 4]
        case .boss: return [0, 5, 3, 4]
        case .shop: return [0, 2, 3, 4]
        case .party: return [0, 3, 4, 3]
        case .space: return [0, 1, 0, 5]
        }
    }

    /// The tune: a scale step each eighth note, -1 for a rest. Eight a bar.
    var melody: [Int] {
        switch self {
        case .calm: return [4, -1, 5, 4, 2, -1, 1, -1, 2, -1, 4, 2, 1, -1, 0, -1]
        case .adventure: return [0, 2, 4, 5, 4, 2, 4, -1, 5, 4, 2, 4, 2, 1, 0, -1]
        case .spooky: return [0, -1, 2, 1, 0, -1, -2, -1, 3, -1, 2, 1, 0, -1, -1, -1]
        case .race: return [4, 4, 5, 4, 2, 4, 5, 7, 7, 5, 4, 2, 4, 2, 1, 0]
        case .boss: return [0, 0, 3, 0, 4, 0, 3, 2, 0, 0, 5, 4, 3, 2, 1, -1]
        case .shop: return [2, 4, 5, -1, 4, 2, 0, -1, 1, 2, 4, -1, 2, 1, 0, -1]
        case .party: return [0, 2, 4, 2, 5, 4, 2, 4, 0, 2, 4, 5, 7, 5, 4, -1]
        case .space: return [4, -1, -1, 6, -1, -1, 5, -1, 4, -1, -1, 2, -1, -1, 1, -1]
        }
    }

    /// Eighth notes in one pass of the tune; the music loops after this.
    public var loopLength: Int { progression.count * 8 }

    /// Seconds per eighth note.
    public var stepSeconds: Double { 60 / tempo / 2 }

    /// What plays on eighth note `step` (counting from the start).
    public func notes(at step: Int) -> [MusicNote] {
        let local = ((step % loopLength) + loopLength) % loopLength
        let bar = local / 8
        let beat = local % 8
        let chordDegree = progression[bar % progression.count]
        var notes: [MusicNote] = []

        // Bass on the beat: the chord's root, an octave down.
        if beat % 2 == 0 {
            notes.append(MusicNote(midi: pitch(of: chordDegree) - 12 + (beat == 4 ? 7 : 0), steps: 2, voice: .bass, velocity: 0.55))
        }
        // A soft chord at the start of each bar.
        if beat == 0 {
            for offset in [0, 2, 4] {
                notes.append(MusicNote(midi: pitch(of: chordDegree + offset), steps: 8, voice: .pad, velocity: 0.22))
            }
        }
        // The tune.
        let pattern = melody
        let degree = pattern[local % pattern.count]
        if degree != -1 {
            notes.append(MusicNote(midi: pitch(of: degree) + 12, steps: 1, voice: .lead, velocity: 0.4))
        }
        // Drums for the busier tracks.
        switch self {
        case .race, .boss, .party, .adventure:
            if beat % 4 == 0 { notes.append(MusicNote(midi: 36, steps: 1, voice: .drum, velocity: 0.7)) }
            if beat % 4 == 2 { notes.append(MusicNote(midi: 38, steps: 1, voice: .drum, velocity: 0.45)) }
        case .calm, .spooky, .shop, .space:
            break
        }
        return notes
    }

    /// The MIDI note of scale degree `degree` (it may run past the scale).
    func pitch(of degree: Int) -> Int {
        let count = scale.count
        let octave = Int((Double(degree) / Double(count)).rounded(.down))
        let index = ((degree % count) + count) % count
        return root + octave * 12 + scale[index]
    }
}

public struct MusicNote: Hashable, Sendable {
    public enum Voice: String, Sendable { case lead, bass, pad, drum }
    public var midi: Int
    /// Eighth notes it lasts.
    public var steps: Int
    public var voice: Voice
    public var velocity: Float

    /// Its pitch in hertz.
    public var frequency: Float {
        440 * pow(2, Float(midi - 69) / 12)
    }
}

/// The music a script asked for.
public struct MusicPlay: Codable, Hashable, Sendable {
    public var track: String
    public var volume: Float

    public init(track: String, volume: Float = 1) {
        self.track = track
        self.volume = Swift.max(0, Swift.min(1, volume.isFinite ? volume : 1))
    }
}

// MARK: - The way, a player's things, conversations, shops, time, rankings

/// An arrow on the player's screen pointing at a place.
public struct Waypoint: Codable, Hashable, Sendable {
    public var position: Vec3
    public var label: String
    public var color: ColorRGBA?

    public init(position: Vec3, label: String = "", color: ColorRGBA? = nil) {
        self.position = position
        self.label = String(label.prefix(40))
        self.color = color
    }
}

/// Something a player is carrying.
public struct InventoryItem: Codable, Hashable, Sendable, Identifiable {
    public static let maximumItems = 24
    public var name: String
    /// An emoji, or an SF Symbol name.
    public var icon: String
    public var count: Int

    public var id: String { name }

    public init(name: String, icon: String = "", count: Int = 1) {
        self.name = String(name.prefix(32))
        self.icon = String(icon.prefix(40))
        self.count = count
    }
}

/// A character talking to the player, with answers to pick.
public struct DialogBox: Codable, Hashable, Sendable {
    public static let maximumChoices = 4
    public var id: String
    public var speaker: String
    public var text: String
    public var choices: [String]

    public init(id: String, speaker: String, text: String, choices: [String]) {
        self.id = String(id.prefix(40))
        self.speaker = String(speaker.prefix(32))
        self.text = String(text.prefix(400))
        self.choices = Array(choices.prefix(Self.maximumChoices).map { String($0.prefix(40)) })
    }
}

public struct ShopOffer: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var price: Int
    public var icon: String

    public var id: String { name }

    public init(name: String, price: Int, icon: String = "") {
        self.name = String(name.prefix(32))
        self.price = Swift.max(0, price)
        self.icon = String(icon.prefix(40))
    }
}

/// A shop window on the player's screen.
public struct ShopPanel: Codable, Hashable, Sendable {
    public static let maximumOffers = 24
    public var id: String
    public var title: String
    /// What the prices are counted in, as shown ("coins").
    public var currency: String
    public var balance: Int
    public var offers: [ShopOffer]

    public init(id: String, title: String, currency: String, balance: Int, offers: [ShopOffer]) {
        self.id = String(id.prefix(40))
        self.title = String(title.prefix(40))
        self.currency = String(currency.prefix(20))
        self.balance = balance
        self.offers = Array(offers.prefix(Self.maximumOffers))
    }
}

/// A big timer on the screen.
public struct CountdownDisplay: Codable, Hashable, Sendable {
    public var label: String
    /// Seconds left when it was sent.
    public var seconds: Double

    public init(label: String, seconds: Double) {
        self.label = String(label.prefix(40))
        self.seconds = Swift.max(0, Swift.min(86_400, seconds.isFinite ? seconds : 0))
    }
}

public struct LeaderboardRow: Codable, Hashable, Sendable {
    public var name: String
    public var value: Double
}

/// A world's best scores, kept on the host's iPad between games.
public struct Leaderboard: Codable, Hashable, Sendable {
    public static let keptRows = 10
    public var title: String
    public var lowerIsBetter: Bool
    public private(set) var rows: [LeaderboardRow] = []

    public init(title: String, lowerIsBetter: Bool = false) {
        self.title = String(title.prefix(40))
        self.lowerIsBetter = lowerIsBetter
    }

    /// Keeps a player's best. True when the table changed.
    @discardableResult
    public mutating func submit(name: String, value: Double) -> Bool {
        guard value.isFinite else { return false }
        let name = String(name.prefix(AvatarProfile.maximumNameLength))
        if let index = rows.firstIndex(where: { $0.name == name }) {
            let old = rows[index].value
            guard lowerIsBetter ? value < old : value > old else { return false }
            rows[index].value = value
        } else {
            rows.append(LeaderboardRow(name: name, value: value))
        }
        let before = rows
        rows.sort { lowerIsBetter ? $0.value < $1.value : $0.value > $1.value }
        if rows.count > Self.keptRows { rows.removeLast(rows.count - Self.keptRows) }
        return rows != before || rows.contains { $0.name == name && $0.value == value }
    }

    public func rank(of name: String) -> Int? {
        rows.firstIndex { $0.name == name }.map { $0 + 1 }
    }
}

/// What the player sees of a leaderboard.
public struct LeaderboardPanel: Codable, Hashable, Sendable {
    public var title: String
    public var rows: [LeaderboardRow]
    public var lowerIsBetter: Bool

    public init(_ board: Leaderboard) {
        title = board.title
        rows = board.rows
        lowerIsBetter = board.lowerIsBetter
    }
}

/// Buttons the runtime puts on screens for its own parts — using a thing,
/// answering, buying, getting out of a vehicle — sent back like any script
/// button, and caught before the script's `on button` sees them.
public enum ReservedButton: Equatable, Sendable {
    case use(item: String)
    case choose(dialog: String, index: Int)
    case buy(shop: String, item: String)
    case closeDialog
    case closeShop
    case closeLeaderboard
    case exitVehicle

    static let prefix = "__"

    public var id: String {
        switch self {
        case let .use(item): return "__use:\(item)"
        case let .choose(dialog, index): return "__choice:\(index):\(dialog)"
        case let .buy(shop, item): return "__buy:\(shop):\(item)"
        case .closeDialog: return "__close:dialog"
        case .closeShop: return "__close:shop"
        case .closeLeaderboard: return "__close:board"
        case .exitVehicle: return "__exit_vehicle"
        }
    }

    public init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        let body = id.dropFirst(Self.prefix.count)
        if body.hasPrefix("use:") {
            self = .use(item: String(body.dropFirst(4)))
        } else if body.hasPrefix("choice:") {
            let rest = body.dropFirst(7)
            guard let colon = rest.firstIndex(of: ":"), let index = Int(rest[..<colon]) else { return nil }
            self = .choose(dialog: String(rest[rest.index(after: colon)...]), index: index)
        } else if body.hasPrefix("buy:") {
            let rest = body.dropFirst(4)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            self = .buy(shop: String(rest[..<colon]), item: String(rest[rest.index(after: colon)...]))
        } else if body == "close:dialog" {
            self = .closeDialog
        } else if body == "close:shop" {
            self = .closeShop
        } else if body == "close:board" {
            self = .closeLeaderboard
        } else if body == "exit_vehicle" {
            self = .exitVehicle
        } else {
            return nil
        }
    }
}

// MARK: - Platforms that move by themselves

public enum MovingParts {

    /// Where a moving platform is, relative to where it was built, at `time`
    /// seconds: waits, goes to `offset`, waits, comes back — for ever. Every
    /// iPad works it out from its own clock, so nothing is sent while it runs.
    public static func offset(for gimmick: GimmickSettings, at time: Double) -> Vec3 {
        let travel = Swift.max(0.2, gimmick.moveSeconds)
        let pause = Swift.max(0, gimmick.movePause)
        let cycle = 2 * (travel + pause)
        guard time.isFinite, cycle > 0 else { return .zero }
        let t = time.truncatingRemainder(dividingBy: cycle)
        let local = t < 0 ? t + cycle : t
        let amount: Double
        switch local {
        case ..<pause: amount = 0
        case ..<(pause + travel): amount = ease((local - pause) / travel)
        case ..<(2 * pause + travel): amount = 1
        default: amount = 1 - ease((local - 2 * pause - travel) / travel)
        }
        return gimmick.moveOffset * Float(amount)
    }

    private static func ease(_ t: Double) -> Double {
        let x = Swift.max(0, Swift.min(1, t))
        return x * x * (3 - 2 * x)
    }

    /// The world with every moving platform where it is at `time`.
    public static func placed(_ world: WorldDocument, at time: Double) -> WorldDocument {
        var moved = world
        for index in moved.blocks.indices where moved.blocks[index].behavior == .elevator {
            moved.blocks[index].position += offset(for: moved.blocks[index].gimmick, at: time)
        }
        return moved
    }
}

// MARK: - Swimming and climbing

/// Where the player is, for how they move.
public enum Surroundings: Equatable, Sendable {
    case normal
    /// In water, whose top is at `surface`.
    case water(surface: Float)
    /// Against a ladder.
    case ladder

    /// Water around the chest, or a ladder within reach.
    public static func find(at position: Vec3, body: CharacterBody, in index: WorldIndex) -> Surroundings {
        let reach = body.bounds(at: position).expanded(by: 0.3)
        let chest = Vec3(position.x, position.y + body.height * 0.45, position.z)
        for entry in index.entries(near: reach) where entry.isVisible {
            if entry.isLiquid, entry.bounds.contains(chest) {
                return .water(surface: entry.bounds.max.y)
            }
            if entry.behavior == .ladder, reach.penetrates(entry.bounds) {
                return .ladder
            }
        }
        return .normal
    }
}

// MARK: - Keeping leaderboards

/// A world's leaderboards on the host's iPad: one small file per world, in
/// Application Support/Leaderboards. Whoever hosts keeps their own — there is
/// no server to hold one for everybody.
public struct LeaderboardStore: Sendable {
    public let directory: URL

    public init(directory: URL = LeaderboardStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Leaderboards", isDirectory: true)
    }

    private func url(for worldID: UUID) -> URL {
        directory.appendingPathComponent(worldID.uuidString).appendingPathExtension("json")
    }

    public func load(worldID: UUID) -> [String: Leaderboard] {
        guard let data = try? Data(contentsOf: url(for: worldID)),
              let boards = try? JSONDecoder().decode([String: Leaderboard].self, from: data) else { return [:] }
        return boards
    }

    public func save(_ boards: [String: Leaderboard], worldID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(boards) else { return }
        try? data.write(to: url(for: worldID), options: .atomic)
    }

    public func delete(worldID: UUID) {
        try? FileManager.default.removeItem(at: url(for: worldID))
    }
}
