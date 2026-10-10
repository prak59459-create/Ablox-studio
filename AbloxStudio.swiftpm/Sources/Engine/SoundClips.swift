import Foundation
import AVFoundation
import AbloxCore

/// A recording, as numbers: one channel, `rate` samples a second, silence
/// trimmed from both ends and the loudest moment at the same level as every
/// other clip's, so a quiet click and a loud bang sit together in a game.
final class SoundClip: Sendable {
    let samples: [Float]
    let rate: Double

    init(samples: [Float], rate: Double) {
        self.samples = samples
        self.rate = rate
    }

    var seconds: Double { Double(samples.count) / rate }
    var bytes: Int { samples.count * MemoryLayout<Float>.size }
}

/// Turns files and text into `SoundClip`s.
enum SoundClipDecoder {

    /// The loudest sample after `tidy`.
    static let peak: Float = 0.9

    /// A clip from bytes written as base64: how the built-in cues are kept
    /// inside the app (`CueRecordings`, written by scripts/cue-recordings.py).
    /// The first byte says how the rest is stored: 1, μ-law, a byte a
    /// sample; 2, IMA ADPCM, three bytes of starting state and then two
    /// samples a byte.
    static func clip(packedBase64 text: String, rate: Double) -> SoundClip? {
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters), data.count > 1 else { return nil }
        let bytes = [UInt8](data)
        let samples: [Float]
        switch bytes[0] {
        case 1: samples = muLaw(bytes, from: 1)
        case 2: samples = imaADPCM(bytes, from: 1)
        default: return nil
        }
        guard samples.count > 1 else { return nil }
        return SoundClip(samples: samples, rate: rate)
    }

    private static func muLaw(_ bytes: [UInt8], from start: Int) -> [Float] {
        let table = muLawTable
        var samples = [Float](repeating: 0, count: bytes.count - start)
        for index in start..<bytes.count {
            samples[index - start] = table[Int(bytes[index])]
        }
        return samples
    }

    private static func imaADPCM(_ bytes: [UInt8], from start: Int) -> [Float] {
        guard bytes.count > start + 3 else { return [] }
        var index = Int(min(88, bytes[start]))
        var predictor = Int(Int16(bitPattern: UInt16(bytes[start + 1]) | (UInt16(bytes[start + 2]) << 8)))
        var samples: [Float] = []
        samples.reserveCapacity(1 + (bytes.count - start - 3) * 2)
        samples.append(Float(predictor) / 32_768)
        for position in (start + 3)..<bytes.count {
            let byte = bytes[position]
            for code in [Int(byte & 0x0F), Int(byte >> 4)] {
                let step = adpcmSteps[index]
                var delta = step >> 3
                if code & 4 != 0 { delta += step }
                if code & 2 != 0 { delta += step >> 1 }
                if code & 1 != 0 { delta += step >> 2 }
                predictor = code & 8 != 0 ? predictor - delta : predictor + delta
                predictor = max(-32_768, min(32_767, predictor))
                index = max(0, min(88, index + adpcmIndex[code]))
                samples.append(Float(predictor) / 32_768)
            }
        }
        return samples
    }

    private static let adpcmSteps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107,
        118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
        6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
        32767
    ]

    private static let adpcmIndex: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    /// G.711 μ-law, all 256 values.
    private static let muLawTable: [Float] = (0..<256).map { value -> Float in
        let byte = ~UInt8(value)
        let sign: Float = (byte & 0x80) != 0 ? -1 : 1
        let exponent = Int((byte >> 4) & 0x07)
        let mantissa = Int(byte & 0x0F)
        let magnitude = ((mantissa << 3) + 0x84) << exponent
        return sign * Float(magnitude - 0x84) / 32_635
    }

    /// A clip from an audio file the iPad can read (the library's MP3s).
    /// Slow enough to keep off the main thread.
    static func clip(contentsOf url: URL, maximumSeconds: Double = 12) -> SoundClip? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0 else { return nil }
        let frames = AVAudioFrameCount(min(Double(file.length), rate * maximumSeconds))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            return nil
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard count > 0, channelCount > 0 else { return nil }
        var samples = [Float](repeating: 0, count: count)
        let share = 1 / Float(channelCount)
        for channel in 0..<channelCount {
            let source = channels[channel]
            for index in 0..<count {
                samples[index] += source[index] * share
            }
        }
        tidy(&samples, rate: rate)
        guard samples.count > 1 else { return nil }
        return SoundClip(samples: samples, rate: rate)
    }

    /// Cuts the quiet off both ends (MP3 files carry some), fades the last
    /// few milliseconds so nothing clicks, and brings the peak to `peak`.
    static func tidy(_ samples: inout [Float], rate: Double) {
        var loudest: Float = 0
        for value in samples { loudest = max(loudest, Swift.abs(value)) }
        guard loudest > 0.000_1 else {
            samples = []
            return
        }
        let threshold = loudest * 0.003
        let first = samples.firstIndex { Swift.abs($0) > threshold } ?? 0
        let last = samples.lastIndex { Swift.abs($0) > threshold } ?? (samples.count - 1)
        let lead = Int(rate * 0.002)
        let tail = Int(rate * 0.02)
        let start = max(0, first - lead)
        let end = min(samples.count, last + tail)
        if start > 0 || end < samples.count {
            samples = Array(samples[start..<end])
        }
        let gain = min(8, peak / loudest)
        let fade = min(samples.count, Int(rate * 0.008))
        let count = samples.count
        for index in 0..<count {
            var value = samples[index] * gain
            let fromEnd = count - index
            if fromEnd <= fade { value *= Float(fromEnd) / Float(fade) }
            samples[index] = value
        }
    }
}

/// Library sounds already decoded, by id, the least recently played
/// dropped first once they add up to more than `limitBytes`.
final class SoundClipCache: @unchecked Sendable {
    static let shared = SoundClipCache()

    var limitBytes = 48 * 1024 * 1024

    private let lock = NSLock()
    private var clips: [String: SoundClip] = [:]
    private var order: [String] = []
    private var bytes = 0

    func clip(for id: String) -> SoundClip? {
        lock.withLock { () -> SoundClip? in
            guard let clip = clips[id] else { return nil }
            if let index = order.firstIndex(of: id) {
                order.remove(at: index)
                order.append(id)
            }
            return clip
        }
    }

    func store(_ clip: SoundClip, for id: String) {
        lock.withLock {
            if let old = clips[id] {
                bytes -= old.bytes
                order.removeAll { $0 == id }
            }
            clips[id] = clip
            order.append(id)
            bytes += clip.bytes
            while bytes > limitBytes, order.count > 1 {
                let oldest = order.removeFirst()
                if let dropped = clips.removeValue(forKey: oldest) { bytes -= dropped.bytes }
            }
        }
    }

    func removeAll() {
        lock.withLock {
            clips.removeAll()
            order.removeAll()
            bytes = 0
        }
    }
}
