import XCTest
@testable import AbloxCore

/// The words the fixtures were made from, rebuilt the same way Python did.
private func fixtureWords(_ count: Int, seed: Int) -> [UInt8] {
    let vocabulary = ["block", "ablox", "world", "script", "player", "coin", "jump", "tower", "neon", "glass", "spawn", "round",
                      "score", "friend", "ipad", "build"]
    var x = seed
    var out: [UInt8] = []
    while out.count < count {
        x = (x * 1_103_515_245 + 12_345) % 2_147_483_648
        let word = vocabulary[(x >> 16) % vocabulary.count]
        out.append(contentsOf: Array(word.utf8))
        out.append((x >> 8) % 7 == 0 ? 10 : 32)
    }
    return Array(out.prefix(count))
}

private func bytes(_ base64: String) -> [UInt8] {
    [UInt8](Data(base64Encoded: base64)!)
}

final class InflateTests: XCTestCase {

    private let text = fixtureWords(40_000, seed: 7)

    func testTheWordsMatchTheFixtures() {
        XCTAssertEqual(CRC32.checksum(text), 547_980_499)
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testDynamicFixedStoredAndFastBlocksAllDecode() throws {
        XCTAssertEqual(try Inflate.decompress(bytes(UpdateFixtures.dynamic), limit: 1 << 20), text)
        XCTAssertEqual(try Inflate.decompress(bytes(UpdateFixtures.fast), limit: 1 << 20), text)
        XCTAssertEqual(try Inflate.decompress(bytes(UpdateFixtures.fixed), limit: 1 << 20), Array(text.prefix(3000)))
        XCTAssertEqual(try Inflate.decompress(bytes(UpdateFixtures.stored), limit: 1 << 20), Array(text.prefix(5000)))
    }

    func testLongOverlappingCopies() throws {
        let expected = [UInt8](repeating: 97, count: 1000) + Array(String(repeating: "abc", count: 500).utf8) + [UInt8](repeating: 0, count: 3000)
        let result = try Inflate.decompress(bytes(UpdateFixtures.runs), limit: 1 << 20)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(CRC32.checksum(result), 3_011_857_555)
    }

    func testAZipBombStopsAtTheLimit() {
        // Twenty-nine bytes that grow to 5 500: over a limit of 4 000.
        XCTAssertThrowsError(try Inflate.decompress(bytes(UpdateFixtures.runs), limit: 4000)) { error in
            XCTAssertEqual(error as? Inflate.Failure, .tooLarge)
        }
    }

    func testTruncatedAndGarbageInputFailInsteadOfCrashing() {
        let whole = bytes(UpdateFixtures.dynamic)
        for cut in [0, 1, 7, 100, whole.count / 2, whole.count - 1] {
            XCTAssertThrowsError(try Inflate.decompress(Array(whole.prefix(cut)), limit: 1 << 20), "cut at \(cut)")
        }
        var x: UInt64 = 4
        func next(_ n: Int) -> Int {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((x >> 33) % UInt64(n))
        }
        for _ in 0..<200 {
            let junk = (0..<(1 + next(300))).map { _ in UInt8(next(256)) }
            // Either an answer or an error; never a trap or a hang.
            _ = try? Inflate.decompress(junk, limit: 1 << 16)
        }
    }
}

final class ZipArchiveTests: XCTestCase {

    func testReadsAGitHubStyleArchive() throws {
        let zip = try ZipArchive(bytes(UpdateFixtures.good))
        XCTAssertEqual(zip.entries.map(\.name), [
            "Ablox-3f2a9c/", "Ablox-3f2a9c/README.md", "Ablox-3f2a9c/Ablox.swiftpm/", "Ablox-3f2a9c/Ablox.swiftpm/Package.swift",
            "Ablox-3f2a9c/Ablox.swiftpm/Sources/App.swift", "Ablox-3f2a9c/Ablox.swiftpm/Sources/Core/Words.swift",
            "Ablox-3f2a9c/Ablox.swiftpm/.DS_Store", "Ablox-3f2a9c/docs/guide.md"
        ])
        let words = try zip.contents(of: zip.entries[5])
        XCTAssertEqual(words, Array(fixtureWords(40_000, seed: 7).prefix(20_000)))
        XCTAssertEqual(String(decoding: try zip.contents(of: zip.entries[4]), as: UTF8.self), "print(\"hello\")\n")
    }

    func testAFlippedByteIsCaughtByTheChecksum() throws {
        let zip = try ZipArchive(bytes(UpdateFixtures.bad))
        XCTAssertThrowsError(try zip.contents(of: zip.entries[4])) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .checksum("Ablox-3f2a9c/Ablox.swiftpm/Sources/App.swift"))
        }
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipArchive(Array("<html>rate limited</html>".utf8))) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZip)
        }
        XCTAssertThrowsError(try ZipArchive([UInt8]()))
    }

    func testPathsThatWouldEscapeAreRefused() {
        XCTAssertEqual(ZipArchive.safePath("Ablox.swiftpm/Sources/App.swift"), "Ablox.swiftpm/Sources/App.swift")
        XCTAssertEqual(ZipArchive.safePath("Ablox.swiftpm/Sources/"), "Ablox.swiftpm/Sources")
        for evil in ["../x", "a/../../x", "/etc/passwd", "a\\..\\x", "C:/x", "a//b", "", "./a", "a/./b", "a\0b"] {
            XCTAssertNil(ZipArchive.safePath(evil), evil)
        }
    }
}

final class AppUpdateTests: XCTestCase {

    private func manifest(_ version: String, build: Int = 1, protocolVersion: Int = AbloxProtocol.version) -> UpdateManifest {
        UpdateManifest(app: "Ablox", version: AppVersion(version)!, build: build, protocolVersion: protocolVersion,
                       date: "2026-09-26", package: "Ablox.swiftpm", notes: ["en": ["New"], "ja": ["新しい"]])
    }

    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10")!)
        XCTAssertLessThan(AppVersion("1.2.3")!, AppVersion("2")!)
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertEqual(AppVersion(" 1.2.0 ")?.description, "1.2.0")
        for bad in ["", "1..2", "v1.2", "1.-2", "1.2.3.4.5", "١.٢", "1.2a"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testWhatCountsAsAnUpdate() {
        let installed = AppVersion("1.1")!
        XCTAssertEqual(UpdatePolicy.availability(installed: installed, build: 3, manifest: manifest("1.1", build: 3)), .current)
        XCTAssertEqual(UpdatePolicy.availability(installed: installed, build: 3, manifest: manifest("1.0", build: 9)), .current)
        XCTAssertEqual(UpdatePolicy.availability(installed: installed, build: 3, manifest: manifest("1.1", build: 4)), .newer(required: false))
        XCTAssertEqual(UpdatePolicy.availability(installed: installed, build: 3, manifest: manifest("1.2")), .newer(required: false))
        // Friends on the new version could not play with this one.
        XCTAssertEqual(UpdatePolicy.availability(installed: installed, build: 3, manifest: manifest("1.2", protocolVersion: AbloxProtocol.version + 1)),
                       .newer(required: true))
    }

    func testSkippingAVersionUnlessItIsRequiredOrSomethingNewerComes() {
        let skipped = AppVersion("1.2")
        XCTAssertFalse(UpdatePolicy.shouldOffer(manifest("1.2"), availability: .newer(required: false), skipped: skipped))
        XCTAssertTrue(UpdatePolicy.shouldOffer(manifest("1.3"), availability: .newer(required: false), skipped: skipped))
        XCTAssertTrue(UpdatePolicy.shouldOffer(manifest("1.2"), availability: .newer(required: true), skipped: skipped))
        XCTAssertFalse(UpdatePolicy.shouldOffer(manifest("1.2"), availability: .current, skipped: nil))
    }

    func testChecksAreSpacedOut() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdatePolicy.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-7 * 3600), now: now))
        XCTAssertTrue(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "clock set back")
    }

    func testReadingAManifest() throws {
        let json = #"{"app":"Ablox","version":"1.2.0","build":5,"protocol":6,"date":"2026-09-26","package":"Ablox.swiftpm","notes":{"en":["A","B"],"ja":["あ"]}}"#
        let read = try UpdateManifest.decode(Data(json.utf8), forApp: "Ablox")
        XCTAssertEqual(read.version, AppVersion("1.2"))
        XCTAssertEqual(read.protocolVersion, 6)
        XCTAssertEqual(read.notes(for: "ja"), ["あ"])
        XCTAssertEqual(read.notes(for: "fr"), ["A", "B"])

        XCTAssertThrowsError(try UpdateManifest.decode(Data(json.utf8), forApp: "Ablox Studio")) { error in
            XCTAssertEqual(error as? UpdateManifest.Problem, .otherApp("Ablox"))
        }
        let sneaky = json.replacingOccurrences(of: "\"Ablox.swiftpm\"", with: "\"../Ablox.swiftpm\"")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(sneaky.utf8), forApp: "Ablox"))
        XCTAssertThrowsError(try UpdateManifest.decode(Data("<html>".utf8), forApp: "Ablox"))
        XCTAssertThrowsError(try UpdateManifest.decode(Data(repeating: 32, count: 40_000), forApp: "Ablox"))
    }

    func testTheRepositoryFilesManifestReadsAndMatchesTheApp() throws {
        // update.json at the top of this repository is what every iPad reads.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("update.json"))
        // The same tests run in Ablox Studio's repository, against its own.
        let app = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["app"] as? String ?? ""
        XCTAssertTrue(["Ablox", "Ablox Studio"].contains(app), app)
        let read = try UpdateManifest.decode(data, forApp: app)
        XCTAssertEqual(read.protocolVersion, AbloxProtocol.version, "update.json names an old protocol")
        XCTAssertFalse(read.notes(for: "en").isEmpty)
        XCTAssertFalse(read.notes(for: "ja").isEmpty)
    }

    func testChannelURLs() {
        let channel = UpdateChannel(owner: "prak59459-create", repository: "Ablox")
        XCTAssertEqual(channel.manifestURL?.absoluteString, "https://raw.githubusercontent.com/prak59459-create/Ablox/HEAD/update.json")
        XCTAssertEqual(channel.archiveURL?.absoluteString, "https://github.com/prak59459-create/Ablox/archive/HEAD.zip")
        let branch = UpdateChannel(owner: "a", repository: "b", branch: "claude/x-1")
        XCTAssertEqual(branch.archiveURL?.absoluteString, "https://github.com/a/b/archive/refs/heads/claude/x-1.zip")
        XCTAssertNil(UpdateChannel(owner: "a/b", repository: "c").manifestURL)
        XCTAssertNil(UpdateChannel(owner: "a", repository: "..").manifestURL)
        XCTAssertNil(UpdateChannel(owner: "a", repository: "b", branch: "../main").manifestURL)
    }

    func testFindsTheProjectInTheDownloadAndUnpacksIt() throws {
        let package = try UpdatePackage(archive: try ZipArchive(bytes(UpdateFixtures.good)), package: "Ablox.swiftpm")
        XCTAssertEqual(package.files.map(\.path), [
            "Ablox.swiftpm/Package.swift", "Ablox.swiftpm/Sources/App.swift", "Ablox.swiftpm/Sources/Core/Words.swift"
        ])
        XCTAssertEqual(package.folders, ["Ablox.swiftpm", "Ablox.swiftpm/Sources", "Ablox.swiftpm/Sources/Core"])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // An older copy there is replaced, not merged with.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Ablox.swiftpm/Old"), withIntermediateDirectories: true)
        try package.write(into: folder)
        let written = try String(contentsOf: folder.appendingPathComponent("Ablox.swiftpm/Sources/App.swift"), encoding: .utf8)
        XCTAssertEqual(written, "print(\"hello\")\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Ablox.swiftpm/Old").path))
    }

    func testAnArchiveWithoutTheProjectOrWithEscapingPathsIsRefused() throws {
        let good = try ZipArchive(bytes(UpdateFixtures.good))
        XCTAssertThrowsError(try UpdatePackage(archive: good, package: "AbloxStudio.swiftpm")) { error in
            XCTAssertEqual(error as? UpdatePackage.Problem, .notFound("AbloxStudio.swiftpm"))
        }
        let evil = try ZipArchive(bytes(UpdateFixtures.evil))
        XCTAssertThrowsError(try UpdatePackage(archive: evil, package: "Ablox.swiftpm")) { error in
            XCTAssertEqual(error as? UpdatePackage.Problem, .unsafePath("Ablox-1/Ablox.swiftpm/../../evil.txt"))
        }
        let bad = try ZipArchive(bytes(UpdateFixtures.bad))
        XCTAssertThrowsError(try UpdatePackage(archive: bad, package: "Ablox.swiftpm")) { error in
            XCTAssertEqual(error as? UpdatePackage.Problem, .archive(.checksum("Ablox-3f2a9c/Ablox.swiftpm/Sources/App.swift")))
        }
    }
}
