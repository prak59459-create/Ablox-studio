import XCTest
@testable import AbloxCore

/// Pulling `.absc` files from a GitHub repository: every URL is built here
/// from checked parts, and everything GitHub answers is treated as untrusted.
final class ScriptSourceTests: XCTestCase {

    private let source = ScriptSource(repository: "prak59459-create/AbloxGames", branch: "main", folder: "games/zombies/scripts")

    // MARK: Addresses

    func testTheListingAndFileAddresses() {
        XCTAssertTrue(source.isValid)
        XCTAssertEqual(source.listingURL?.absoluteString,
                       "https://api.github.com/repos/prak59459-create/AbloxGames/contents/games/zombies/scripts?ref=main")
        XCTAssertEqual(source.fileURL(named: "main.absc")?.absoluteString,
                       "https://raw.githubusercontent.com/prak59459-create/AbloxGames/main/games/zombies/scripts/main.absc")
        XCTAssertEqual(source.displayName, "prak59459-create/AbloxGames@main/games/zombies/scripts")
    }

    func testTheTopLevelAndStraySlashes() {
        let top = ScriptSource(repository: "a/b", folder: " /scripts/ ")
        XCTAssertEqual(top.cleanFolder, "scripts")
        XCTAssertEqual(ScriptSource(repository: "a/b").listingURL?.absoluteString,
                       "https://api.github.com/repos/a/b/contents?ref=main")
        XCTAssertEqual(ScriptSource(repository: "a/b").fileURL(named: "x.absc")?.absoluteString,
                       "https://raw.githubusercontent.com/a/b/main/x.absc")
    }

    func testBranchesWithSlashesWork() {
        let feature = ScriptSource(repository: "a/b", branch: "feature/new-map")
        XCTAssertTrue(feature.isValid)
        XCTAssertEqual(feature.fileURL(named: "m.absc")?.absoluteString,
                       "https://raw.githubusercontent.com/a/b/feature/new-map/m.absc")
    }

    func testAnythingThatCouldLeaveTheRepositoryIsRefused() {
        for folder in ["../other", "a/../../b", ".git", "a//b", "a:b", "a?x=1", "a#b", "%2e%2e"] {
            XCTAssertFalse(ScriptSource(repository: "a/b", folder: folder).isValid, folder)
        }
        for branch in ["", "..", "../main", "/main", "main/", "-x", "a b", "main?x", "main#", ".hidden"] {
            XCTAssertFalse(ScriptSource(repository: "a/b", branch: branch).isValid, branch)
        }
        for repository in ["", "a", "a/b/c", "https://evil.com/a", "../a/b"] {
            XCTAssertFalse(ScriptSource(repository: repository).isValid, repository)
        }
        XCTAssertNil(ScriptSource(repository: "a/b").listingURL.flatMap { _ in ScriptSource(repository: "a/b", branch: "..").listingURL })
    }

    func testFileNamesFromTheListingCannotBecomePaths() {
        XCTAssertNil(source.fileURL(named: "../secret.absc"))
        XCTAssertNil(source.fileURL(named: "main.swift"))
        XCTAssertNotNil(source.fileURL(named: "ゲーム.absc"))
    }

    func testTheGameListBranchIsCheckedToo() {
        XCTAssertNotNil(CatalogueSource(repository: "a/b", reference: "test").indexURL)
        XCTAssertNil(CatalogueSource(repository: "a/b", reference: "../main").indexURL)
        XCTAssertEqual(CatalogueSource(repository: "a/b", reference: "dev").indexURL?.absoluteString,
                       "https://raw.githubusercontent.com/a/b/dev/index.json")
    }

    func testSettingsFallBackToSomethingThatWorks() {
        XCTAssertEqual(CatalogueSource.chosen(repository: " club/games ", branch: " test "),
                       CatalogueSource(repository: "club/games", reference: "test"))
        XCTAssertEqual(CatalogueSource.chosen(repository: "club/games", branch: ""),
                       CatalogueSource(repository: "club/games", reference: "main"), "an empty branch means main")
        XCTAssertEqual(CatalogueSource.chosen(repository: "club/games", branch: "../x"),
                       CatalogueSource(repository: "club/games", reference: "main"))
        XCTAssertEqual(CatalogueSource.chosen(repository: "club", branch: "test"), .default,
                       "half a repository name is the built-in list, whatever the branch")
    }

    // MARK: GitHub's listing

    private func listing(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }

    func testOnlyAbscFilesAreTaken() throws {
        let data = try listing([
            ["name": "main.absc", "type": "file", "size": 120, "download_url": "https://evil.example/x"],
            ["name": "ui.absc", "type": "file", "size": 80],
            ["name": "README.md", "type": "file", "size": 10],
            ["name": "old", "type": "dir", "size": 0],
            ["name": "huge.absc", "type": "file", "size": 50_000_000],
            ["name": ".hidden.absc", "type": "file", "size": 1],
            ["name": "Main Menu.absc", "type": "file", "size": 5]
        ])
        let files = try ScriptSource.parseListing(data)
        XCTAssertEqual(files.map(\.name), ["Main Menu.absc", "main.absc", "ui.absc"])
    }

    func testAFileInsteadOfAFolderIsExplained() throws {
        let single = try JSONSerialization.data(withJSONObject: ["name": "main.absc", "type": "file"])
        XCTAssertThrowsError(try ScriptSource.parseListing(single)) { error in
            XCTAssertEqual(error as? ScriptSource.ListingError, .notAFolder)
        }
        XCTAssertThrowsError(try ScriptSource.parseListing(Data("nope".utf8))) { error in
            XCTAssertEqual(error as? ScriptSource.ListingError, .malformed)
        }
    }

    func testAListingIsCappedAtTheFileLimit() throws {
        let many = (1...50).map { ["name": "f\($0).absc", "type": "file", "size": 1] as [String: Any] }
        XCTAssertEqual(try ScriptSource.parseListing(listing(many)).count, ScriptFile.Limits.maximumFiles)
    }

    // MARK: Merging

    func testPullingReplacesAddsAndNeverDeletes() {
        let mine = ScriptFile(name: "mine", source: "print(\"only on the iPad\")")
        let main = ScriptFile(name: "main", source: "old", isEnabled: false)
        let ui = ScriptFile(name: "ui", source: "same")
        let (files, result) = ScriptSource.merge(
            [("MAIN.absc", "new"), ("ui.absc", "same"), ("npc.absc", "print(1)")],
            into: [mine, main, ui]
        )
        XCTAssertEqual(files.map(\.name), ["mine.absc", "main.absc", "ui.absc", "npc.absc"])
        XCTAssertEqual(files[1].source, "new")
        XCTAssertEqual(files[1].id, main.id, "the same file, updated")
        XCTAssertFalse(files[1].isEnabled, "a switched-off file stays off")
        XCTAssertEqual(result.updated, ["main.absc"])
        XCTAssertEqual(result.added, ["npc.absc"])
        XCTAssertEqual(result.unchanged, ["ui.absc"])
        XCTAssertTrue(result.changedAnything)
        XCTAssertTrue(result.summary.contains("npc.absc"))
    }

    func testPullingRespectsTheFileLimit() {
        let full = (1...ScriptFile.Limits.maximumFiles).map { ScriptFile(name: "f\($0)", source: "") }
        let (files, result) = ScriptSource.merge([("extra.absc", "x")], into: full)
        XCTAssertEqual(files.count, ScriptFile.Limits.maximumFiles)
        XCTAssertEqual(result.skipped, ["extra.absc"])
    }

    func testNothingNewSaysSo() {
        let (_, result) = ScriptSource.merge([("a.absc", "x")], into: [ScriptFile(name: "a", source: "x")])
        XCTAssertFalse(result.changedAnything)
        XCTAssertEqual(result.summary, L("Already up to date."))
    }

    // MARK: Saved with the world

    func testTheSourceIsSavedWithTheWorldAndTravels() throws {
        var world = WorldDocument(name: "Synced")
        world.scriptSource = ScriptSource(repository: "a/b", branch: "dev", folder: "s", updatesOnPlay: true)
        let restored = try JSONDecoder().decode(WorldDocument.self, from: JSONEncoder().encode(world))
        XCTAssertEqual(restored.scriptSource, world.scriptSource)

        let plain = try JSONEncoder().encode(WorldDocument(name: "Plain"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("scriptSource"), "absent unless set")

        var other = WorldDocument(name: "Peer")
        let delta = WorldDelta.scriptSourceChanged(world.scriptSource)
        XCTAssertTrue(try JSONDecoder().decode(WorldDelta.self, from: JSONEncoder().encode(delta)).apply(to: &other))
        XCTAssertEqual(other.scriptSource?.branch, "dev")
    }
}
