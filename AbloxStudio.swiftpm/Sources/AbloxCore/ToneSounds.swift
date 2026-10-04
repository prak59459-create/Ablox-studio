import Foundation

// Sounds made from numbers, in a file of its own, split from
// WorldFeatures.swift: a change here rebuilds only the files that use what
// is here, not every file that uses anything that was declared beside it.

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
