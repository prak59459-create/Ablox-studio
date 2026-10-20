import XCTest
@testable import AbloxCore

/// Songs of the player's own: which files may be added, and what plays where.
final class MyMusicTests: XCTestCase {

    func testSongsAreNamedAfterTheirFileAndOnlyMusicIsTaken() throws {
        let id = UUID()
        let track = try MyMusic.track(forFileNamed: "Lobby_Theme v2.MP3", bytes: 3_000_000, existing: 0, id: id).get()
        XCTAssertEqual(track.title, "Lobby Theme v2")
        XCTAssertEqual(track.fileName, "\(id.uuidString).mp3", "named by its id, so no two can clash")

        XCTAssertEqual(MyMusic.track(forFileNamed: "picture.png", bytes: 10, existing: 0), .failure(.notMusic))
        XCTAssertEqual(MyMusic.track(forFileNamed: "song", bytes: 10, existing: 0), .failure(.notMusic))
        XCTAssertEqual(MyMusic.track(forFileNamed: "huge.wav", bytes: MyMusic.maximumBytes + 1, existing: 0), .failure(.tooBig))
        XCTAssertEqual(MyMusic.track(forFileNamed: "empty.m4a", bytes: 0, existing: 0), .failure(.tooBig))
        XCTAssertEqual(MyMusic.track(forFileNamed: "one.m4a", bytes: 10, existing: MyMusic.maximumTracks), .failure(.tooMany))
        XCTAssertEqual(MyMusic.title(fromFileNamed: "__.m4a"), L("My song"))
        XCTAssertEqual(MyMusic.title(fromFileNamed: String(repeating: "a", count: 200) + ".m4a").count, MyMusic.maximumTitleLength)
    }

    func testThePlazaAndGamesEachPlayTheirChosenSong() {
        let plaza = UUID(), game = UUID()
        let both: Set<UUID> = [plaza, game]
        XCTAssertEqual(MyMusic.playback(inPlaza: true, gameMusic: .calm, volume: 1, soundOn: true,
                                        plazaSong: plaza, gameSong: game, available: both), .mine(plaza, volume: 1))
        XCTAssertEqual(MyMusic.playback(inPlaza: false, gameMusic: .race, volume: 0.5, soundOn: true,
                                        plazaSong: plaza, gameSong: game, available: both), .mine(game, volume: 0.5))
        // Nothing chosen for games: the game's own music, as before.
        XCTAssertEqual(MyMusic.playback(inPlaza: false, gameMusic: .race, volume: 1, soundOn: true,
                                        plazaSong: plaza, gameSong: nil, available: both), .game(.race, volume: 1))
    }

    func testAQuietGameStaysQuietAndADeletedSongFallsBack() {
        let song = UUID()
        XCTAssertEqual(MyMusic.playback(inPlaza: false, gameMusic: nil, volume: 1, soundOn: true,
                                        plazaSong: nil, gameSong: song, available: [song]), .silence)
        XCTAssertEqual(MyMusic.playback(inPlaza: true, gameMusic: nil, volume: 1, soundOn: true,
                                        plazaSong: song, gameSong: nil, available: [song]), .mine(song, volume: 1),
                       "the Plaza plays its song even if it had no music")
        XCTAssertEqual(MyMusic.playback(inPlaza: true, gameMusic: .calm, volume: 1, soundOn: true,
                                        plazaSong: song, gameSong: nil, available: []), .game(.calm, volume: 1))
        XCTAssertEqual(MyMusic.playback(inPlaza: true, gameMusic: .calm, volume: 1, soundOn: false,
                                        plazaSong: song, gameSong: nil, available: [song]), .silence)
    }

    func testTheChoicesAreKeptAndOlderSettingsHaveNone() throws {
        var preferences = PlayPreferences()
        preferences.plazaSong = UUID()
        preferences.gameSong = UUID()
        let data = try JSONEncoder().encode(preferences)
        let back = try JSONDecoder().decode(PlayPreferences.self, from: data)
        XCTAssertEqual(back.plazaSong, preferences.plazaSong)
        XCTAssertEqual(back.gameSong, preferences.gameSong)

        let old = try JSONDecoder().decode(PlayPreferences.self, from: Data(#"{"musicVolume":0.5}"#.utf8))
        XCTAssertNil(old.plazaSong)
        XCTAssertNil(old.gameSong)
        XCTAssertEqual(old.musicVolume, 0.5)
    }
}
