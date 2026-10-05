import Foundation
import AVFoundation
import AbloxCore

/// Ablox's sound effects and music, made from numbers as they play.
///
/// Every cue is a few tones (`SoundCue.tones`) and every piece of music a
/// loop of notes (`MusicTrack.notes(at:)`), so there are still no audio
/// files in the playground: one `AVAudioSourceNode` adds up the tones that
/// are sounding, sample by sample. If the audio engine will not start — no
/// output, another app holding the hardware — the caller falls back to the
/// system sounds it always had.
final class SoundSynth: @unchecked Sendable {

    static let shared = SoundSynth()

    /// Settings → Sound, 0 to 1.
    var effectsGain: Float {
        get { lock.withLock { _effectsGain } }
        set { lock.withLock { _effectsGain = max(0, min(1, newValue)) } }
    }

    var musicGain: Float {
        get { lock.withLock { _musicGain } }
        set { lock.withLock { _musicGain = max(0, min(1, newValue)) } }
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    private var sampleRate: Double = 44_100
    private var failed = false
    private var tapInstalled = false

    // Everything below is touched by the audio thread, under the lock.

    private struct Voice {
        var phase: Double = 0
        var start: Double
        var end: Double
        /// Samples it lasts, and how far through it is.
        var length: Int
        var position: Int = 0
        /// Samples to wait before it starts.
        var delay: Int
        var wave: ToneStep.Wave
        var volume: Float
        var isMusic: Bool
    }

    private var voices: [Voice] = []
    private var _effectsGain: Float = 1
    private var _musicGain: Float = 0.7
    private var noise: UInt32 = 0x9E37_79B9

    /// The loop of the music playing, worked out once when it starts.
    private var loop: [[MusicNote]] = []
    private var loopStepSamples = 0
    private var loopStep = 0
    private var untilNextStep = 0
    private var musicVolume: Float = 1
    private var track: MusicTrack?

    private init() {
        voices.reserveCapacity(256)
    }

    // MARK: Starting

    /// Starts the engine if it is not running. False when it cannot.
    @discardableResult
    func start() -> Bool {
        if failed { return false }
        if engine.isRunning { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // Ambient: mixes with a child's own music, and the silent switch
            // silences it, like the system sounds it replaces.
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            if source == nil {
                let rate = session.sampleRate > 0 ? session.sampleRate : 44_100
                sampleRate = rate
                guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
                    failed = true
                    return false
                }
                let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList -> OSStatus in
                    self.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
                    return noErr
                }
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                source = node
            }
            try engine.start()
            return true
        } catch {
            failed = true
            return false
        }
    }

    /// Hears everything the engine plays — for game clips. Nil stops.
    /// Called on the main thread; `listener` runs on the audio thread.
    func listen(_ listener: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
        let mixer = engine.mainMixerNode
        if tapInstalled {
            mixer.removeTap(onBus: 0)
            tapInstalled = false
        }
        guard let listener else { return }
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in listener(buffer, time) }
        tapInstalled = true
    }

    func stop() {
        lock.withLock {
            voices.removeAll(keepingCapacity: true)
            track = nil
            loop = []
        }
        engine.pause()
    }

    // MARK: Effects

    /// Plays a cue. False when the engine is not available.
    @discardableResult
    func play(_ cue: SoundCue, volume: Float = 1, pitch: Float = 1) -> Bool {
        guard start() else { return false }
        let rate = sampleRate
        lock.withLock {
            guard voices.count < 200 else { return }
            var offset = 0
            for tone in cue.tones {
                let length = max(1, Int(Double(tone.duration) * rate))
                voices.append(Voice(start: Double(tone.frequency * pitch), end: Double(tone.endFrequency * pitch),
                                    length: length, delay: offset, wave: tone.wave,
                                    volume: tone.volume * volume, isMusic: false))
                offset += length
            }
        }
        return true
    }

    // MARK: Music

    /// Plays `track` on a loop, or stops the music with nil.
    func setMusic(_ track: MusicTrack?, volume: Float = 1) {
        let current = lock.withLock { self.track }
        if track == current {
            lock.withLock { musicVolume = volume }
            return
        }
        guard let track else {
            lock.withLock {
                self.track = nil
                loop = []
                voices.removeAll { $0.isMusic }
            }
            return
        }
        guard start() else { return }
        let notes = (0..<track.loopLength).map { track.notes(at: $0) }
        let stepSamples = max(1, Int(track.stepSeconds * sampleRate))
        lock.withLock {
            voices.removeAll { $0.isMusic }
            self.track = track
            loop = notes
            loopStepSamples = stepSamples
            loopStep = 0
            untilNextStep = 0
            musicVolume = volume
        }
    }

    // MARK: Rendering (audio thread)

    private func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, let samples = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.lock()
        let effectsGain = _effectsGain
        let musicGain = _musicGain * musicVolume
        let rate = sampleRate
        for frame in 0..<frames {
            if !loop.isEmpty {
                if untilNextStep <= 0 {
                    startNotes(loop[loopStep % loop.count])
                    loopStep = (loopStep + 1) % loop.count
                    untilNextStep = loopStepSamples
                }
                untilNextStep -= 1
            }
            var mix: Float = 0
            for index in voices.indices {
                if voices[index].delay > 0 {
                    voices[index].delay -= 1
                    continue
                }
                mix += sample(&voices[index], rate: rate) * (voices[index].isMusic ? musicGain : effectsGain)
            }
            samples[frame] = max(-1, min(1, mix * 0.6))
        }
        voices.removeAll { $0.position >= $0.length }
        lock.unlock()

        let bytes = frames * MemoryLayout<Float>.size
        for buffer in buffers.dropFirst() {
            if let data = buffer.mData { memcpy(data, samples, bytes) }
        }
    }

    private func startNotes(_ notes: [MusicNote]) {
        let rate = sampleRate
        let step = Double(loopStepSamples)
        for note in notes where voices.count < 240 {
            let length = max(1, Int(step * Double(note.steps) * 0.92))
            switch note.voice {
            case .drum:
                if note.midi == 36 {
                    voices.append(Voice(start: 120, end: 45, length: Int(0.16 * rate), delay: 0, wave: .sine,
                                        volume: note.velocity * 0.9, isMusic: true))
                } else {
                    voices.append(Voice(start: 1_000, end: 400, length: Int(0.09 * rate), delay: 0, wave: .noise,
                                        volume: note.velocity * 0.35, isMusic: true))
                }
            case .bass:
                voices.append(Voice(start: Double(note.frequency), end: Double(note.frequency), length: length, delay: 0,
                                    wave: .triangle, volume: note.velocity * 0.5, isMusic: true))
            case .pad:
                voices.append(Voice(start: Double(note.frequency), end: Double(note.frequency), length: length, delay: 0,
                                    wave: .sine, volume: note.velocity * 0.5, isMusic: true))
            case .lead:
                voices.append(Voice(start: Double(note.frequency), end: Double(note.frequency), length: length, delay: 0,
                                    wave: .square, volume: note.velocity * 0.22, isMusic: true))
            }
        }
    }

    // Written in small typed steps: as a few long expressions the compiler
    // spent over a second choosing among number overloads here.
    private func sample(_ voice: inout Voice, rate: Double) -> Float {
        let position: Double = Double(voice.position)
        let length: Double = Double(voice.length)
        let progress: Double = position / length
        let span: Double = voice.end - voice.start
        let frequency: Double = voice.start + span * progress
        let phase: Double = voice.phase
        let value: Float
        switch voice.wave {
        case .sine:
            let angle: Double = phase * 2.0 * Double.pi
            value = Float(sin(angle))
        case .square:
            value = phase < 0.5 ? 0.6 : -0.6
        case .triangle:
            let distance: Double = Swift.abs(phase - 0.5)
            value = Float(4.0 * distance - 1.0)
        case .saw:
            let ramp: Double = 2.0 * phase - 1.0
            value = Float(ramp) * 0.7
        case .noise:
            noise ^= noise << 13
            noise ^= noise >> 17
            noise ^= noise << 5
            let unit: Float = Float(noise) / Float(UInt32.max)
            value = unit * 2.0 - 1.0
        }
        var next: Double = phase + frequency / rate
        if next >= 1.0 { next -= next.rounded(.down) }
        voice.phase = next

        // A quick fade in and a longer fade out, so nothing clicks.
        let attackFrames: Int = Swift.max(1, Swift.min(voice.length / 8, Int(rate * 0.006)))
        let releaseFrames: Int = Swift.max(1, voice.length / 4)
        let attack: Float = Swift.min(1.0, Float(voice.position) / Float(attackFrames))
        let release: Float = Swift.min(1.0, Float(voice.length - voice.position) / Float(releaseFrames))
        voice.position += 1
        return value * voice.volume * attack * release
    }
}

/// Reads a character's lines aloud, when the player has asked for it.
@MainActor
final class LineReader {
    static let shared = LineReader()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, volume: Float = 1) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: String(trimmed.prefix(300)))
        // Japanese text in a Japanese voice, whatever the iPad's language.
        let japanese = trimmed.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: japanese ? "ja-JP" : AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.volume = max(0, min(1, volume))
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
