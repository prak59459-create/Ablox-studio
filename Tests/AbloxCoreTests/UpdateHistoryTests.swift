import XCTest
@testable import AbloxCore

final class UpdateHistoryTests: XCTestCase {

    private func release(_ version: String, _ build: Int, _ note: String = "x") -> UpdateHistory.Release {
        UpdateHistory.Release(version: AppVersion(version)!, build: build, date: "2026-10-01",
                              notes: ["en": [note], "ja": ["\(note) ja"]])
    }

    func testReadsNewestFirstWithoutRepeats() throws {
        let json = """
        {"app": "Ablox", "releases": [
          {"version": "1.9", "build": 8, "date": "2026-09-29", "notes": {"en": ["old"], "ja": ["古い"]}},
          {"version": "5.8", "build": 47, "date": "2026-10-10", "notes": {"en": ["new"], "ja": ["新しい"]}},
          {"version": "1.9", "build": 8, "date": "2026-09-29", "notes": {"en": ["again"]}}
        ]}
        """
        let history = try UpdateHistory.decode(Data(json.utf8), forApp: "Ablox")
        XCTAssertEqual(history.releases.map(\.version.description), ["5.8", "1.9"])
        XCTAssertEqual(history.releases[1].notes(for: "ja"), ["古い"])
        XCTAssertEqual(history.releases[0].notes(for: "fr"), ["new"])
    }

    func testRefusesAnotherAppsOrABrokenOrHugeHistory() {
        let studio = #"{"app": "Ablox Studio", "releases": []}"#
        XCTAssertThrowsError(try UpdateHistory.decode(Data(studio.utf8), forApp: "Ablox"))
        XCTAssertThrowsError(try UpdateHistory.decode(Data("<html>".utf8), forApp: "Ablox"))
        XCTAssertThrowsError(try UpdateHistory.decode(Data(repeating: 32, count: UpdateHistory.Limits.maximumBytes + 1),
                                                      forApp: "Ablox"))
    }

    func testLongNotesAreCut() throws {
        let long = String(repeating: "a", count: 1_000)
        let lines = (0..<40).map { _ in "\"\(long)\"" }.joined(separator: ",")
        let json = #"{"app": "Ablox", "releases": [{"version": "2.0", "build": 9, "date": "d", "notes": {"en": [\#(lines)]}}]}"#
        let history = try UpdateHistory.decode(Data(json.utf8), forApp: "Ablox")
        let notes = history.releases[0].notes(for: "en")
        XCTAssertEqual(notes.count, UpdateManifest.Limits.maximumNoteLines)
        XCTAssertEqual(notes[0].count, UpdateManifest.Limits.maximumNoteLength)
    }

    func testTheNewestManifestIsAddedWhenTheHistoryIsBehind() {
        let history = UpdateHistory(app: "Ablox", releases: [release("5.7", 46)])
        let manifest = UpdateManifest(app: "Ablox", version: AppVersion("5.8")!, build: 47, protocolVersion: AbloxProtocol.version,
                                      date: "2026-10-10", package: "Ablox.swiftpm", notes: ["en": ["latest"]])
        XCTAssertEqual(history.including(manifest).releases.map(\.build), [47, 46])
        // Already there: not listed twice.
        XCTAssertEqual(history.including(manifest).including(manifest).releases.count, 2)
        XCTAssertEqual(history.including(nil), history)
    }

    func testStandingAgainstThisIPad() {
        let installed = AppVersion("5.8")!
        XCTAssertEqual(UpdateHistory.standing(of: release("5.8", 47), installed: installed, build: 47), .installed)
        XCTAssertEqual(UpdateHistory.standing(of: release("5.9", 48), installed: installed, build: 47), .newer)
        XCTAssertEqual(UpdateHistory.standing(of: release("5.8", 48), installed: installed, build: 47), .newer)
        XCTAssertEqual(UpdateHistory.standing(of: release("5.7", 46), installed: installed, build: 47), .older)
    }

    func testHistoryURLSitsBesideTheManifest() {
        let channel = UpdateChannel(owner: "prak59459-create", repository: "Ablox")
        XCTAssertEqual(channel.historyURL?.absoluteString,
                       "https://raw.githubusercontent.com/prak59459-create/Ablox/HEAD/changelog.json")
        let branch = UpdateChannel(owner: "a", repository: "b", branch: "claude/x-1")
        XCTAssertEqual(branch.historyURL?.absoluteString, "https://raw.githubusercontent.com/a/b/claude/x-1/changelog.json")
        XCTAssertNil(UpdateChannel(owner: "a/..", repository: "b").historyURL)
    }

    func testTheRepositorysHistoryReadsAndStartsWithTheNewestRelease() throws {
        // changelog.json beside update.json is what Settings → Updates →
        // Update history reads. The same test runs in Ablox Studio's
        // repository, against its own.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifestData = try Data(contentsOf: root.appendingPathComponent("update.json"))
        let app = (try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])?["app"] as? String ?? ""
        let manifest = try UpdateManifest.decode(manifestData, forApp: app)
        let history = try UpdateHistory.decode(Data(contentsOf: root.appendingPathComponent("changelog.json")), forApp: app)
        XCTAssertEqual(history.releases.first, UpdateHistory.Release(manifest),
                       "changelog.json is behind update.json: run python3 scripts/changelog.py")
        for entry in history.releases {
            XCTAssertFalse(entry.notes(for: "en").isEmpty, entry.version.description)
            XCTAssertFalse(entry.notes(for: "ja").isEmpty, entry.version.description)
        }
    }
}

final class GameRevisionTests: XCTestCase {

    private func listing(bytes: Int? = 400_000, updatedAt: TimeInterval = 1_790_000_000,
                         scripts: [String]? = ["games/a/main.absc"]) -> GameListing {
        GameListing(id: "a", title: "A", world: "games/a/world.ablox", scripts: scripts, blockCount: 645,
                    updatedAt: Date(timeIntervalSince1970: updatedAt), bytes: bytes)
    }

    func testTheSameListingIsTheSameRevision() {
        XCTAssertEqual(listing().revision, listing().revision)
        XCTAssertTrue(GameRevision.isCurrent(stamp: listing().revision, for: listing()))
        XCTAssertTrue(GameRevision.isCurrent(stamp: listing().revision + "\n", for: listing()))
    }

    func testANewerGameInTheListMakesTheDownloadOld() {
        // Last Survivor Games grew new rounds and files but kept its date:
        // its size and scripts changed, and that alone must count.
        let old = listing().revision
        XCTAssertFalse(GameRevision.isCurrent(stamp: old, for: listing(bytes: 400_855)))
        XCTAssertFalse(GameRevision.isCurrent(stamp: old, for: listing(scripts: ["games/a/main.absc", "games/a/ring.absc"])))
        XCTAssertFalse(GameRevision.isCurrent(stamp: old, for: listing(updatedAt: 1_790_100_000)))
        XCTAssertFalse(GameRevision.isCurrent(stamp: old, for: listing(bytes: nil)))
    }

    func testADownloadWithNoStampIsOld() {
        // Downloaded by a build before stamps: which version it is, nobody
        // knows, so it is fetched again once.
        XCTAssertFalse(GameRevision.isCurrent(stamp: nil, for: listing()))
        XCTAssertFalse(GameRevision.isCurrent(stamp: "", for: listing()))
    }
}
