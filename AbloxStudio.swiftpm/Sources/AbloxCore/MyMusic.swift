import Foundation

/// Music of the player's own (8.5, from the suggestion box): songs they made
/// or may use, added from the Files app, to play in the Plaza (the lobby
/// between games) and, if they like, in games instead of the game's music.
///
/// The songs stay on this iPad: nothing is sent to the other players, who
/// hear their own choice or the game's music. The files live in the app's
/// own folder (`MyMusicPlayer` in Engine); here are the rules about them and
/// the choice of what plays, so they can be tested off the iPad.
public enum MyMusic {
    /// How many songs, so the iPad's storage is not filled by mistake.
    public static let maximumTracks = 30
    /// The biggest file: about half an hour of an ordinary song.
    public static let maximumBytes = 40_000_000
    /// What iPadOS plays without anything extra.
    public static let fileExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aif", "aiff"]
    /// The longest name shown.
    public static let maximumTitleLength = 60

    public struct Track: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        /// In the music folder: `<id>.<extension>`.
        public var fileName: String
        public var bytes: Int

        public init(id: UUID = UUID(), title: String, fileName: String, bytes: Int) {
            self.id = id
            self.title = title
            self.fileName = fileName
            self.bytes = bytes
        }
    }

    /// Why a file was not added.
    public enum Refusal: Error, Equatable, Sendable {
        case notMusic
        case tooBig
        case tooMany

        public var message: String {
            switch self {
            case .notMusic: return L("That file is not a song Ablox can play (m4a, mp3, wav, aac, caf or aiff).")
            case .tooBig: return L("That song is too big (40 MB at most).")
            case .tooMany: return L("There are already {} songs. Delete one to add another.", MyMusic.maximumTracks)
            }
        }
    }

    /// The track a file becomes, or why it cannot: named after the file,
    /// without its extension.
    public static func track(forFileNamed name: String, bytes: Int, existing: Int, id: UUID = UUID()) -> Result<Track, Refusal> {
        let ext = (name as NSString).pathExtension.lowercased()
        guard fileExtensions.contains(ext) else { return .failure(.notMusic) }
        guard bytes > 0, bytes <= maximumBytes else { return .failure(.tooBig) }
        guard existing < maximumTracks else { return .failure(.tooMany) }
        return .success(Track(id: id, title: title(fromFileNamed: name), fileName: "\(id.uuidString).\(ext)", bytes: bytes))
    }

    /// "My Song (final).mp3" → "My Song (final)": what the list shows.
    public static func title(fromFileNamed name: String) -> String {
        let bare = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        let cleaned = bare.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = cleaned.isEmpty ? L("My song") : cleaned
        return String(shown.prefix(maximumTitleLength))
    }

    /// What to play now.
    public enum Playback: Equatable, Sendable {
        /// The game's music (nil for none), as before.
        case game(MusicTrack?, volume: Float)
        /// A song of the player's own, on a loop.
        case mine(UUID, volume: Float)
        case silence
    }

    /// The Plaza plays the song chosen for it; a game plays the one chosen
    /// for games, wherever the game would play music. A game that has gone
    /// quiet on purpose (a scary moment) stays quiet. A chosen song that has
    /// been deleted falls back to the game's own music.
    public static func playback(inPlaza: Bool, gameMusic: MusicTrack?, volume: Float, soundOn: Bool,
                                plazaSong: UUID?, gameSong: UUID?, available: Set<UUID>) -> Playback {
        guard soundOn else { return .silence }
        let chosen = inPlaza ? plazaSong : gameSong
        if let chosen, available.contains(chosen), inPlaza || gameMusic != nil {
            return .mine(chosen, volume: volume)
        }
        return gameMusic.map { .game($0, volume: volume) } ?? .silence
    }
}
