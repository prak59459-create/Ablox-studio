import Foundation

// Music made from numbers, in a file of its own, split from
// WorldFeatures.swift: a change here rebuilds only the files that use what
// is here, not every file that uses anything that was declared beside it.

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
