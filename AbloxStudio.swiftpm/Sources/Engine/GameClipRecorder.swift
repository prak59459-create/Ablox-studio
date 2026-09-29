import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import RealityKit
import AbloxCore

/// The last half minute of a game, kept by Ablox itself.
///
/// ReplayKit's clip buffer needs iPadOS to ask the player first, and an app
/// run from Swift Playgrounds cannot show that question: the system answers
/// with a BSActionErrorDomain error instead, so clips never started. Here
/// the 3D view's own frames — the same picture, world effects and all, only
/// without the buttons over it — and the game's own sounds are written ten
/// seconds to a file, and the last few files are joined when a clip is
/// saved. Nothing to allow, nothing sent anywhere.
///
/// Frames arrive on RealityKit's render thread (`capture`), sounds on the
/// audio thread (`hear`); both are written on one queue of this class's own.
final class GameClipRecorder: @unchecked Sendable {

    static let shared = GameClipRecorder()

    /// Seconds in one file, and at least how much is kept.
    static let pieceSeconds: Double = 10
    static let keptSeconds: Double = 45
    static let framesPerSecond: Double = 30
    /// The longer side of the picture, in pixels.
    static let longestSide: CGFloat = 1280

    enum Failure: Error {
        case nothingYet
        case couldNotJoin
    }

    // MARK: Render-thread state, under `lock`

    private let lock = NSLock()
    private var recording = false
    private var lastFrame: Double = 0
    private var ciContext: CIContext?
    private var textureCache: CVMetalTextureCache?
    private var pool: (pool: CVPixelBufferPool, width: Int, height: Int)?

    // MARK: Writing, on `queue`

    private let queue = DispatchQueue(label: "ablox.clips", qos: .userInitiated)

    private final class Piece {
        let url: URL
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audio: AVAssetWriterInput?
        let width: Int
        let height: Int
        var start: CMTime?
        var last: CMTime = .invalid
        var audioSamples = 0

        init(url: URL, writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             audio: AVAssetWriterInput?, width: Int, height: Int) {
            self.url = url
            self.writer = writer
            self.video = video
            self.adaptor = adaptor
            self.audio = audio
            self.width = width
            self.height = height
        }
    }

    private struct Finished {
        let url: URL
        let start: Double
        let end: Double
        let width: Int
        let height: Int
    }

    private var piece: Piece?
    private var finished: [Finished] = []
    /// Set on the first sound heard; files begun after it carry sound.
    private var audioFormat: AVAudioFormat?
    /// Once writing sound has failed, later files are pictures only.
    private var audioBroken = false
    private var generation = 0
    /// Files being joined into a clip, kept until the join is done.
    private var joining: Set<URL> = []

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ablox-clips", isDirectory: true)
    }

    var isRecording: Bool { lock.withLock { recording } }

    // MARK: Starting and stopping

    func start() {
        lock.withLock {
            recording = true
            lastFrame = 0
        }
        queue.async {
            self.generation += 1
            self.clear()
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        }
        SoundSynth.shared.listen { [weak self] buffer, time in self?.hear(buffer, at: time) }
    }

    func stop() {
        lock.withLock { recording = false }
        SoundSynth.shared.listen(nil)
        queue.async {
            self.generation += 1
            if let piece = self.piece {
                self.piece = nil
                piece.writer.cancelWriting()
            }
            self.clear()
        }
    }

    /// Every file kept, gone. On `queue`.
    private func clear() {
        for piece in finished { try? FileManager.default.removeItem(at: piece.url) }
        finished.removeAll()
        try? FileManager.default.removeItem(at: Self.folder)
    }

    // MARK: Frames (render thread)

    /// One finished frame of the 3D view, from the post-process pass. Draws a
    /// smaller copy into a pixel buffer on the same command buffer, and hands
    /// it to the writer once the GPU has drawn it.
    func capture(_ picture: CIImage, in frame: ARView.PostProcessContext) {
        let now = CACurrentMediaTime()
        let due: Bool = lock.withLock {
            guard recording, now - lastFrame >= 0.9 / Self.framesPerSecond else { return false }
            lastFrame = now
            return true
        }
        guard due else { return }
        let extent = picture.extent
        guard extent.width >= 16, extent.height >= 16, extent.width.isFinite, extent.height.isFinite else { return }
        let scale = min(1, Self.longestSide / max(extent.width, extent.height))
        let width = Int((extent.width * scale / 2).rounded()) * 2
        let height = Int((extent.height * scale / 2).rounded()) * 2
        guard let made = target(width: width, height: height, device: frame.device),
              let metal = CVMetalTextureGetTexture(made.texture) else { return }
        let buffer = made.buffer, texture = made.texture

        let scaled = picture.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let destination = CIRenderDestination(mtlTexture: metal, commandBuffer: frame.commandBuffer)
        destination.isFlipped = false
        _ = try? context(for: frame.device).startTask(toRender: scaled, to: destination)

        let time = CMTime(seconds: now, preferredTimescale: 60_000)
        frame.commandBuffer.addCompletedHandler { [weak self] _ in
            // The texture is held until here so its pixels stay put.
            _ = texture
            self?.queue.async { self?.append(frame: buffer, at: time) }
        }
    }

    private func context(for device: MTLDevice) -> CIContext {
        lock.withLock {
            if let ciContext { return ciContext }
            let made = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            ciContext = made
            return made
        }
    }

    /// A pixel buffer from the pool, and a Metal texture that draws into it.
    /// Nil when the writer has fallen behind: that frame is skipped.
    private func target(width: Int, height: Int, device: MTLDevice) -> (buffer: CVPixelBuffer, texture: CVMetalTexture)? {
        lock.withLock {
            if textureCache == nil {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
            }
            if pool == nil || pool?.width != width || pool?.height != height {
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
                ]
                var made: CVPixelBufferPool?
                CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
                pool = made.map { ($0, width, height) }
            }
            guard let current = pool?.pool, let cache = textureCache else { return nil }
            var buffer: CVPixelBuffer?
            // At most eight frames waiting for the encoder at once.
            let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, current, limit, &buffer) == kCVReturnSuccess,
                  let buffer else { return nil }
            var texture: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
                                                            width, height, 0, &texture) == kCVReturnSuccess,
                  let texture else { return nil }
            return (buffer: buffer, texture: texture)
        }
    }

    // MARK: Sound (audio thread)

    private func hear(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard isRecording, when.isHostTimeValid, buffer.frameLength > 0 else { return }
        let time = CMTime(seconds: AVAudioTime.seconds(forHostTime: when.hostTime), preferredTimescale: 60_000)
        guard let sample = Self.sampleBuffer(buffer, at: time) else { return }
        let format = buffer.format
        queue.async { self.append(sound: sample, format: format, at: time) }
    }

    /// The tap's samples as something a writer takes. Copies them, since the
    /// tap reuses its buffer.
    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        let format = buffer.format
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0,
                                             layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                                   sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                             bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sample
    }

    // MARK: Writing (queue)

    private func append(frame buffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if let current = piece {
            // A new file when this one is long enough, the picture changed
            // size, or play stopped for a while (the iPad was put away): the
            // join leaves gaps out.
            let long = current.start.map { (time - $0).seconds >= Self.pieceSeconds } ?? false
            let gap = current.last.isValid && (time - current.last).seconds > 1
            if long || gap || current.width != width || current.height != height {
                finish(current, then: nil)
            }
        }
        if piece == nil { piece = makePiece(width: width, height: height) }
        guard let piece else { return }
        if piece.start == nil {
            piece.writer.startSession(atSourceTime: time)
            piece.start = time
        }
        guard !piece.last.isValid || time > piece.last, piece.video.isReadyForMoreMediaData else { return }
        if piece.adaptor.append(buffer, withPresentationTime: time) {
            piece.last = time
        } else if piece.writer.status == .failed {
            self.piece = nil
            piece.writer.cancelWriting()
            try? FileManager.default.removeItem(at: piece.url)
        }
    }

    private func append(sound sample: CMSampleBuffer, format: AVAudioFormat, at time: CMTime) {
        if audioFormat == nil { audioFormat = format }
        guard let piece, let audio = piece.audio, let start = piece.start, time >= start,
              audio.isReadyForMoreMediaData else { return }
        if audio.append(sample) {
            piece.audioSamples += 1
        } else if piece.writer.status == .failed {
            // Sound would not go in: this file is lost, and the next ones are
            // pictures only.
            audioBroken = true
            self.piece = nil
            piece.writer.cancelWriting()
            try? FileManager.default.removeItem(at: piece.url)
        }
    }

    private func makePiece(width: Int, height: Int) -> Piece? {
        let url = Self.folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: width * height * 4,
            AVVideoMaxKeyFrameIntervalDurationKey: 1,
            AVVideoExpectedSourceFrameRateKey: Int(Self.framesPerSecond)
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return nil }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

        var audio: AVAssetWriterInput?
        if !audioBroken, let format = audioFormat, format.sampleRate >= 8_000 {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: min(2, max(1, Int(format.channelCount))),
                AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }
        guard writer.startWriting() else { return nil }
        return Piece(url: url, writer: writer, video: video, adaptor: adaptor, audio: audio, width: width, height: height)
    }

    /// Closes a file and keeps it, then drops files older than needed.
    private func finish(_ piece: Piece, then done: (() -> Void)?) {
        if self.piece === piece { self.piece = nil }
        guard let start = piece.start, piece.last.isValid, piece.last > start else {
            piece.writer.cancelWriting()
            try? FileManager.default.removeItem(at: piece.url)
            done?()
            return
        }
        piece.video.markAsFinished()
        piece.audio?.markAsFinished()
        let generation = self.generation
        let kept = Finished(url: piece.url, start: start.seconds, end: piece.last.seconds, width: piece.width, height: piece.height)
        piece.writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                if piece.writer.status == .completed, generation == self.generation {
                    self.finished.append(kept)
                    self.prune()
                } else {
                    // A file with sound that would not close: pictures only from now.
                    if piece.audio != nil, piece.audioSamples == 0 { self.audioBroken = true }
                    try? FileManager.default.removeItem(at: piece.url)
                }
                done?()
            }
        }
    }

    private func prune() {
        guard let newest = finished.last?.end else { return }
        while let oldest = finished.first, newest - oldest.end > Self.keptSeconds, !joining.contains(oldest.url) {
            try? FileManager.default.removeItem(at: oldest.url)
            finished.removeFirst()
        }
    }

    // MARK: Saving

    /// Writes the last `seconds` to `url` as one video. `done` is called on
    /// the recorder's queue with whether it worked.
    func save(seconds: Double, to url: URL, done: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let close: (@escaping () -> Void) -> Void = { next in
                if let piece = self.piece { self.finish(piece, then: next) } else { next() }
            }
            close {
                let urls = self.newest(covering: seconds).map(\.url)
                guard !urls.isEmpty else { return done(false) }
                self.joining.formUnion(urls)
                Task {
                    let worked = (try? await Self.join(urls, lasting: seconds, into: url)) != nil
                    self.queue.async {
                        self.joining.subtract(urls)
                        self.prune()
                        done(worked)
                    }
                }
            }
        }
    }

    /// The newest files of one size that together last at least `seconds`.
    private func newest(covering seconds: Double) -> [Finished] {
        guard let last = finished.last else { return [] }
        var chosen: [Finished] = []
        var total: Double = 0
        for piece in finished.reversed() {
            guard piece.width == last.width, piece.height == last.height, total < seconds else { break }
            chosen.insert(piece, at: 0)
            total += piece.end - piece.start
        }
        return chosen
    }

    /// The files back to back, without the gaps between them, cut to the
    /// last `seconds`, copied rather than encoded again.
    private static func join(_ urls: [URL], lasting seconds: Double, into url: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.couldNotJoin
        }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for file in urls {
            let asset = AVURLAsset(url: file)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await video.load(.timeRange)
            guard range.duration > .zero else { continue }
            try videoTrack.insertTimeRange(range, of: video, at: cursor)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let heard = try await audio.load(.timeRange)
                let start = CMTimeMaximum(heard.start, range.start)
                let end = CMTimeMinimum(heard.end, range.end)
                if end > start {
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try audioTrack?.insertTimeRange(CMTimeRange(start: start, end: end), of: audio, at: cursor + (start - range.start))
                }
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw Failure.nothingYet }
        let wanted = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.couldNotJoin
        }
        export.timeRange = CMTimeRange(start: cursor > wanted ? cursor - wanted : .zero, end: cursor)
        try? FileManager.default.removeItem(at: url)
        if #available(iOS 18, *) {
            try await export.export(to: url, as: .mp4)
        } else {
            export.outputURL = url
            export.outputFileType = .mp4
            await export.export()
            guard export.status == .completed else { throw export.error ?? Failure.couldNotJoin }
        }
    }
}
