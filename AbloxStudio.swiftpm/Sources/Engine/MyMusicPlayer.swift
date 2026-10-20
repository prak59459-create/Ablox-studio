import Foundation
import AVFoundation
import Combine
import AbloxCore

/// The player's own songs (`MyMusic`): kept in the app's folder, listed in
/// `index.json` beside them, and played on a loop in place of the built-in
/// music (`SoundSynth`) when one is chosen.
@MainActor
public final class MyMusicPlayer: ObservableObject {
    public static let shared = MyMusicPlayer()

    @Published public private(set) var tracks: [MyMusic.Track] = []

    private var player: AVAudioPlayer?
    private var playingID: UUID?

    private init() {
        tracks = Self.readIndex()
    }

    /// Application Support/MyMusic.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MyMusic", isDirectory: true)
    }

    private static var indexURL: URL { folder.appendingPathComponent("index.json") }

    private static func readIndex() -> [MyMusic.Track] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([MyMusic.Track].self, from: data) else { return [] }
        // Only the songs whose file is still there.
        return list.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
    }

    private func writeIndex() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    public var available: Set<UUID> { Set(tracks.map(\.id)) }

    // MARK: Adding and deleting

    /// Copies a song chosen in the Files app into the folder. Nil when it
    /// was added, otherwise why not.
    public func add(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        switch MyMusic.track(forFileNamed: url.lastPathComponent, bytes: bytes, existing: tracks.count) {
        case let .failure(refusal):
            return refusal.message
        case let .success(track):
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                let destination = Self.folder.appendingPathComponent(track.fileName)
                try FileManager.default.copyItem(at: url, to: destination)
                // A file that is not really a song is caught here.
                guard (try? AVAudioPlayer(contentsOf: destination)) != nil else {
                    try? FileManager.default.removeItem(at: destination)
                    return MyMusic.Refusal.notMusic.message
                }
                tracks.append(track)
                writeIndex()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    public func delete(_ id: UUID) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        if playingID == id { stop() }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(track.fileName))
        tracks.removeAll { $0.id == id }
        writeIndex()
    }

    // MARK: Playing

    /// Plays the song on a loop, or keeps playing it at the new volume.
    public func play(_ id: UUID, volume: Float) {
        if playingID == id, let player {
            player.volume = volume
            if !player.isPlaying { player.play() }
            return
        }
        stop()
        // The audio session, set up as for the built-in music.
        SoundSynth.shared.start()
        guard let track = tracks.first(where: { $0.id == id }),
              let player = try? AVAudioPlayer(contentsOf: Self.folder.appendingPathComponent(track.fileName)) else { return }
        player.numberOfLoops = -1
        player.volume = volume
        player.play()
        self.player = player
        playingID = id
    }

    public func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    public func isPlaying(_ id: UUID) -> Bool {
        playingID == id && player?.isPlaying == true
    }
}
