import Foundation

// What a world can look like beyond its blocks: weather, the time of day
// and the sky, and a screen look. The rest of what a world can do has a file
// each, so that a change to one rebuilds only what uses it: Particles,
// WorldImage, ToneSounds, MusicTracks, ScriptPanels (the way, a player's
// things, conversations, shops, countdowns, leaderboards), MovingParts,
// Surroundings and LeaderboardStore.
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
