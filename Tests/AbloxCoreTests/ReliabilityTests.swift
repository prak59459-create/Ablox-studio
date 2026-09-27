import XCTest
@testable import AbloxCore

/// The world-list cache, the problem log, notices, controller shaping and
/// colour-vision help.
final class ReliabilityTests: XCTestCase {

    // MARK: World list

    func testTheListCacheOnlyAnswersForUnchangedFiles() {
        var cache = WorldListCache()
        let id = UUID()
        cache.items["a.ablox"] = .init(byteCount: 100, fileModified: 50, id: id, name: "A", authorName: "", modifiedAt: 40, blockCount: 3)
        XCTAssertEqual(cache.item(named: "a.ablox", byteCount: 100, fileModified: 50)?.id, id)
        XCTAssertNil(cache.item(named: "a.ablox", byteCount: 101, fileModified: 50), "a different size is read again")
        XCTAssertNil(cache.item(named: "a.ablox", byteCount: 100, fileModified: 51), "a newer date is read again")
        XCTAssertNil(cache.item(named: "b.ablox", byteCount: 100, fileModified: 50))

        let round = WorldListCache.decoded(from: cache.encoded()!)
        XCTAssertEqual(round, cache)
        XCTAssertEqual(WorldListCache.decoded(from: Data("junk".utf8)), WorldListCache(), "a broken cache is an empty one")
        var old = cache
        old.version = 0
        XCTAssertNil(WorldListCache.decoded(from: old.encoded()!).item(named: "a.ablox", byteCount: 100, fileModified: 50))
    }

    // MARK: Problems

    func testProblemsAreKeptCountedAndCapped() {
        var log = ProblemLog()
        XCTAssertTrue(log.add(.network, "The host went away.", at: 100))
        XCTAssertFalse(log.add(.network, "The host went away.", at: 130), "the same thing again is counted")
        XCTAssertEqual(log.reports.count, 1)
        XCTAssertEqual(log.reports[0].count, 2)
        XCTAssertTrue(log.add(.network, "The host went away.", at: 1_000), "much later it is new")
        XCTAssertFalse(log.add(.other, "   ", at: 1_001), "nothing to say, nothing kept")
        for index in 0..<300 { log.add(.script, "Error \(index)", at: Double(2_000 + index)) }
        XCTAssertEqual(log.reports.count, ProblemLog.maximumReports)
        XCTAssertEqual(log.reports.last?.message, "Error 299")

        let long = String(repeating: "x", count: 5_000)
        log.add(.saving, long, at: 9_000)
        XCTAssertEqual(log.reports.last?.message.count, ProblemLog.maximumMessageLength)

        XCTAssertEqual(ProblemLog.decoded(from: log.encoded()!), log)
    }

    func testTheReportReadsWell() {
        var log = ProblemLog()
        log.add(.script, "line 4: “coins” is not defined", detail: "Lava Obby", at: 0)
        log.add(.crash, "Ablox crashed last time.", at: 60)
        let text = log.text(app: "Ablox", version: "1.1 (2)", device: "iPad", system: "iPadOS 17.5", now: 120,
                            timeZone: TimeZone(identifier: "UTC")!)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Ablox 1.1 (2) — iPad, iPadOS 17.5")
        XCTAssertTrue(lines[1].contains("1970-01-01 00:02:00"))
        XCTAssertTrue(lines[2].contains("crash"), "newest first: \(lines)")
        XCTAssertTrue(text.contains("script (Lava Obby)"))
        XCTAssertTrue(ProblemLog().text(app: "A", version: "1", device: "d", system: "s", now: 0).contains("No problems"))
    }

    func testCrashMarkers() {
        XCTAssertEqual(CrashMarker.signal(in: "hello\n" + CrashMarker.line(for: 11)), 11)
        XCTAssertNil(CrashMarker.signal(in: "nothing here"))
        XCTAssertTrue(CrashMarker.report(signal: 5, doing: "Playing Lava Obby").contains("SIGTRAP"))
        XCTAssertTrue(CrashMarker.report(signal: 5, doing: "Playing Lava Obby").contains("Lava Obby"))
        XCTAssertTrue(CrashMarker.report(signal: nil, doing: nil).contains("unexpectedly"))
        XCTAssertTrue(CrashMarker.signals.contains(5) && CrashMarker.signals.contains(11))
    }

    // MARK: Notices

    func testNoticesAreCheckedAndFiltered() throws {
        let json = """
        {"notices": [
          {"id": "event", "kind": "event", "title": {"en": "Build week", "ja": "ビルド週間"}, "body": {"en": "Make a world!"},
           "from": "2026-09-20", "until": "2026-09-30"},
          {"id": "old", "title": {"en": "Old"}, "until": "2026-01-01"},
          {"id": "new-only", "title": {"en": "New"}, "minVersion": "1.2"},
          {"id": "studio", "title": {"en": "Studio"}, "app": "Ablox Studio"},
          {"id": "", "title": {"en": "No id"}},
          {"id": "event", "title": {"en": "Duplicate"}},
          {"id": "weird", "kind": "surprise", "title": {"en": "Unknown kind is info"}}
        ]}
        """
        let notices = try XCTUnwrap(NoticeBoard.decode(Data(json.utf8)))
        XCTAssertEqual(notices.map(\.id), ["event", "old", "new-only", "studio", "weird"])
        XCTAssertEqual(notices.last?.kind, .info)
        XCTAssertEqual(notices[0].title(in: .japanese), "ビルド週間")
        XCTAssertEqual(notices[0].body(in: .japanese), "Make a world!", "English when there is no Japanese")

        let shown = NoticeBoard.active(notices, app: "Ablox", version: AppVersion("1.1"), today: "2026-09-27", dismissed: ["weird"])
        XCTAssertEqual(shown.map(\.id), ["event"])
        XCTAssertEqual(NoticeBoard.active(notices, app: "Ablox", version: AppVersion("1.2"), today: "2026-10-05", dismissed: [])
            .map(\.id), ["new-only", "weird"])
        XCTAssertNil(NoticeBoard.decode(Data("[]".utf8)))
        XCTAssertEqual(NoticeBoard.day(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!), "1970-01-01")
    }

    func testThePublishedNoticesFileIsValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("notices.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("notices.json lives in the Ablox repository")
        }
        let notices = try XCTUnwrap(NoticeBoard.decode(data), "notices.json does not decode")
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(notices.count, (raw?["notices"] as? [Any])?.count, "every notice in the file is usable")
        for notice in notices {
            XCTAssertFalse(notice.title(in: .japanese).isEmpty, "\(notice.id) needs a title")
        }
    }

    // MARK: Controllers and keys

    func testSticksHaveADeadZoneAndNeverExceedOne() {
        XCTAssertEqual(StickShaping.shaped(x: 0.1, y: 0.05).x, 0)
        let full = StickShaping.shaped(x: 1, y: 1)
        XCTAssertEqual((full.x * full.x + full.y * full.y).squareRoot(), 1, accuracy: 0.001)
        let gentle = StickShaping.shaped(x: 0, y: 0.3)
        XCTAssertGreaterThan(gentle.y, 0)
        XCTAssertLessThan(gentle.y, 0.3)
        XCTAssertEqual(StickShaping.shaped(x: .nan, y: 1).x, 0)
        XCTAssertEqual(StickShaping.lookDegrees(0, seconds: 1 / 60, sensitivity: 1), 0)
        XCTAssertLessThan(StickShaping.lookDegrees(-1, seconds: 1 / 60, sensitivity: 1), 0)
        XCTAssertLessThan(StickShaping.lookDegrees(1, seconds: 5, sensitivity: 1), 25, "a long frame does not spin the camera")
    }

    func testKeysMakeAStick() {
        XCTAssertEqual(KeyMovement.stick(forward: true, back: false, left: false, right: false), Vec3(0, 0, 1))
        XCTAssertEqual(KeyMovement.stick(forward: true, back: true, left: false, right: false), .zero)
        let diagonal = KeyMovement.stick(forward: true, back: false, left: true, right: false)
        XCTAssertEqual(diagonal.length, 1, accuracy: 0.001)
        XCTAssertLessThan(diagonal.x, 0)
    }

    // MARK: Colour vision

    func testColourCorrectionSeparatesRedAndGreen() throws {
        XCTAssertNil(ColourVision.off.matrix)
        for vision in ColourVision.allCases where vision != .off {
            XCTAssertEqual(try XCTUnwrap(vision.matrix).count, 9)
        }
        let red = ColorRGBA(r: 0.9, g: 0.2, b: 0.2), green = ColorRGBA(r: 0.2, g: 0.7, b: 0.2)
        for vision in [ColourVision.redGreen, .red] {
            let a = vision.corrected(red), b = vision.corrected(green)
            XCTAssertGreaterThan(Swift.abs(a.b - b.b), Swift.abs(red.b - green.b), "\(vision): blue now tells them apart")
        }
        let grey = ColourVision.greyscale.corrected(ColorRGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(grey.r, grey.g, accuracy: 0.0001)
        let white = ColourVision.redGreen.corrected(.white)
        XCTAssertEqual(white.r, 1, accuracy: 0.01, "white stays white")
        XCTAssertEqual(white.g, 1, accuracy: 0.01)
        XCTAssertEqual(white.b, 1, accuracy: 0.01)

        XCTAssertEqual(MeaningMark.mark(for: .hazard), .danger)
        XCTAssertEqual(MeaningMark.mark(for: .goal), .goal)
        XCTAssertNil(MeaningMark.mark(for: .none))

        var preferences = PlayPreferences()
        preferences.colourVision = .blueYellow
        preferences.markMeaning = true
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(PlayPreferences.self, from: data).colourVision, .blueYellow)
        let older = try JSONDecoder().decode(PlayPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(older.colourVision, .off)
        XCTAssertFalse(older.markMeaning)
    }

    func testColoursHaveNames() {
        XCTAssertEqual(ColorRGBA(r: 1, g: 1, b: 1).spokenName, L("white"))
        XCTAssertEqual(ColorRGBA(r: 0, g: 0, b: 0).spokenName, L("black"))
        XCTAssertEqual(ColorRGBA(hex: "#FF5A5F")!.spokenName, L("red"))
        XCTAssertEqual(ColorRGBA(hex: "#FFD60A")!.spokenName, L("yellow"))
        XCTAssertEqual(ColorRGBA(hex: "#4ADE80")!.spokenName, L("green"))
        XCTAssertEqual(ColorRGBA(r: 0.05, g: 0.1, b: 0.45).spokenName, L("dark {}", L("blue")))
        XCTAssertEqual(ColorRGBA(r: 0.5, g: 0.5, b: 0.52).spokenName, L("grey"))
        XCTAssertEqual(ColorRGBA(r: 0.45, g: 0.25, b: 0.1).spokenName, L("brown"))
        for color in ColorRGBA.palette {
            XCTAssertFalse(color.spokenName.isEmpty)
        }
    }
}
