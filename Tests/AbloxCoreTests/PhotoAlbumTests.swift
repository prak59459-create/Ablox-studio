import XCTest
@testable import AbloxCore

/// The album and photo mode, the second round.
final class PhotoAlbumTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    func testFileNamesSayGameAndTime() throws {
        let entry = try XCTUnwrap(AlbumEntry.parse("Tower Run 2026-09-28 10.20.30.png", bytes: 2048))
        XCTAssertEqual(entry.game, "Tower Run")
        XCTAssertFalse(entry.isClip)
        XCTAssertEqual(entry.bytes, 2048)
        XCTAssertNotEqual(entry.date, .distantPast)
        let clip = try XCTUnwrap(AlbumEntry.parse("Kart 2026-01-02 03.04.05.MP4"))
        XCTAssertTrue(clip.isClip)
        XCTAssertEqual(clip.game, "Kart")
        let odd = try XCTUnwrap(AlbumEntry.parse("my picture.jpg", fallbackDate: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(odd.game, "my picture")
        XCTAssertEqual(odd.date, Date(timeIntervalSince1970: 5))
        XCTAssertNil(AlbumEntry.parse("notes.txt"))
        XCTAssertNil(AlbumEntry.parse("album"))
    }

    func testNotesKeepHeartsAndCaptions() throws {
        var notes = AlbumNotes()
        XCTAssertTrue(notes.toggleFavourite("a.png"))
        XCTAssertTrue(notes.isFavourite("a.png"))
        notes.setCaption("  Top of the tower!  ", for: "a.png")
        XCTAssertEqual(notes.caption(for: "a.png"), "Top of the tower!")
        notes.copy("a.png", to: "b.png")
        XCTAssertTrue(notes.isFavourite("b.png"))
        XCTAssertEqual(notes.caption(for: "b.png"), "Top of the tower!")
        notes.keepOnly(["b.png"])
        XCTAssertFalse(notes.isFavourite("a.png"))
        XCTAssertNil(notes.caption(for: "a.png"))
        notes.setCaption("", for: "b.png")
        XCTAssertNil(notes.caption(for: "b.png"))
        XCTAssertFalse(notes.toggleFavourite("b.png"))
        let back = try JSONDecoder().decode(AlbumNotes.self, from: JSONEncoder().encode(notes))
        XCTAssertEqual(back, notes)
        XCTAssertEqual(try JSONDecoder().decode(AlbumNotes.self, from: Data("{}".utf8)), AlbumNotes())
    }

    func testFilteringAndSections() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        let entries = [
            AlbumEntry(id: "1.png", game: "Kart", date: now.addingTimeInterval(-60), isClip: false),
            AlbumEntry(id: "2.mp4", game: "Kart", date: now.addingTimeInterval(-day), isClip: true),
            AlbumEntry(id: "3.png", game: "Cafe", date: now.addingTimeInterval(-3 * day), isClip: false),
            AlbumEntry(id: "4.png", game: "Cafe", date: now.addingTimeInterval(-3 * day - 60), isClip: false)
        ]
        var notes = AlbumNotes()
        notes.toggleFavourite("3.png")
        notes.setCaption("ice cream", for: "4.png")
        XCTAssertEqual(AlbumLayout.filter(entries, show: .clips, notes: notes).map(\.id), ["2.mp4"])
        XCTAssertEqual(AlbumLayout.filter(entries, show: .pictures, notes: notes).count, 3)
        XCTAssertEqual(AlbumLayout.filter(entries, show: .favourites, notes: notes).map(\.id), ["3.png"])
        XCTAssertEqual(AlbumLayout.filter(entries, show: .all, notes: notes, game: "Cafe").count, 2)
        XCTAssertEqual(AlbumLayout.filter(entries, show: .all, notes: notes, search: "ICE").map(\.id), ["4.png"])

        let byDay = AlbumLayout.sections(entries, grouping: .day, now: now, calendar: calendar)
        XCTAssertEqual(byDay.count, 3)
        XCTAssertEqual(byDay[0].section, .today)
        XCTAssertEqual(byDay[1].section, .yesterday)
        XCTAssertEqual(byDay[2].entries.map(\.id), ["3.png", "4.png"])
        let oldest = AlbumLayout.sections(entries, grouping: .none, newestFirst: false, now: now, calendar: calendar)
        XCTAssertEqual(oldest.first?.entries.first?.id, "4.png")
        let byGame = AlbumLayout.sections(entries, grouping: .game, now: now, calendar: calendar)
        XCTAssertEqual(byGame.map(\.section), [.game("Kart"), .game("Cafe")])
        XCTAssertEqual(AlbumLayout.games(in: entries).first?.count, 2)
        XCTAssertEqual(AlbumLayout.sections([], grouping: .none).count, 0)
    }

    func testSizes() {
        XCTAssertEqual(AlbumLayout.sizeText(500), L("{} bytes", 500))
        XCTAssertEqual(AlbumLayout.sizeText(12_400), L("{} KB", 12))
        XCTAssertEqual(AlbumLayout.sizeText(12_400_000), L("{} MB", "12.4"))
    }

    func testCropsAndFrames() {
        let square = PhotoCrop.square.rect(width: 1920, height: 1080)
        XCTAssertEqual(square.width, 1080)
        XCTAssertEqual(square.x, 420)
        let tall = PhotoCrop.tall.rect(width: 1920, height: 1080)
        XCTAssertEqual(tall.height, 1080)
        XCTAssertEqual(tall.width, 810)
        let wide = PhotoCrop.wide.rect(width: 1000, height: 1000)
        XCTAssertEqual(wide.width, 1000)
        XCTAssertEqual(wide.height, 563)
        XCTAssertEqual(wide.y, 219)
        let same = PhotoCrop.original.rect(width: 640, height: 480)
        XCTAssertEqual(same.width, 640)
        XCTAssertEqual(same.height, 480)

        XCTAssertEqual(PhotoFrame.none.framedSize(width: 100, height: 50).width, 100)
        let instant = PhotoFrame.instant.framedSize(width: 1000, height: 1000)
        XCTAssertEqual(instant.width, 1100)
        XCTAssertEqual(instant.height, 1250, "a deep edge at the bottom")
    }

    func testPhotoModeOptionsLoadSafely() throws {
        var options = PhotoModeOptions()
        options.timer = 3
        options.burst = true
        options.frame = .film
        XCTAssertEqual(options.shots, 3)
        XCTAssertEqual(try JSONDecoder().decode(PhotoModeOptions.self, from: JSONEncoder().encode(options)), options)
        let odd = try JSONDecoder().decode(PhotoModeOptions.self, from: Data(#"{"timer":7,"zoom":900,"crop":"hexagon","grid":true}"#.utf8))
        XCTAssertEqual(odd.timer, 0)
        XCTAssertEqual(odd.zoom, PhotoModeOptions.zoomRange.upperBound)
        XCTAssertEqual(odd.crop, .original)
        XCTAssertTrue(odd.grid)
        XCTAssertTrue(PhotoModeOptions.stampText(game: "Kart", date: Date()).hasPrefix("Kart · "))
    }
}
