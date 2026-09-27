import XCTest
@testable import AbloxCore

final class ProjectSyncTests: XCTestCase {

    private func manifest(bundle: String = "com.ablox.client", icon: String? = nil, version: String = "1.2") -> [UInt8] {
        var lines = [
            "// No `appIcon:` on purpose.",
            "let package = Package(",
            "    products: [",
            "        .iOSApplication(",
            "            name: \"Ablox\",",
            "            bundleIdentifier: \"\(bundle)\",",
            "            displayVersion: \"\(version)\",",
        ]
        if let icon { lines.append("            appIcon: \(icon),") }
        lines += [
            "            accentColor: .presetColor(.cyan),",
            "            supportedDeviceFamilies: [.pad]",
            "        )",
            "    ]",
            ")",
        ]
        return Array(lines.joined(separator: "\n").utf8)
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testOnlyChangedFilesAreWritten() throws {
        let current = [
            "Package.swift": manifest(),
            "Sources/A.swift": bytes("a"),
            "Sources/UI/B.swift": bytes("b"),
        ]
        let new = [
            "Package.swift": manifest(),
            "Sources/A.swift": bytes("a"),
            "Sources/UI/B.swift": bytes("b, changed"),
            "Sources/UI/C.swift": bytes("new file"),
        ]
        let plan = try ProjectSync.plan(new: new, current: current)
        XCTAssertEqual(Set(plan.writes.keys), ["Sources/UI/B.swift", "Sources/UI/C.swift"])
        XCTAssertEqual(plan.unchanged, 2)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertFalse(plan.isEmpty)
    }

    func testTheSameVersionIsNothingToDo() throws {
        let files = ["Package.swift": manifest(), "Sources/A.swift": bytes("a")]
        let plan = try ProjectSync.plan(new: files, current: files)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.unchanged, 2)
    }

    /// A source file left behind would still be compiled, and could
    /// define something twice (a file moved from one folder to another).
    func testMovedSourceFilesLeaveNothingBehind() throws {
        let current = [
            "Package.swift": manifest(),
            "Sources/AbloxCore/AppleBridging.swift": bytes("bridges"),
            "Sources/Notes.txt": bytes("mine"),
        ]
        let new = [
            "Package.swift": manifest(),
            "Sources/Engine/AppleBridging.swift": bytes("bridges"),
        ]
        let plan = try ProjectSync.plan(new: new, current: current)
        XCTAssertEqual(plan.deletions, ["Sources/AbloxCore/AppleBridging.swift"])
        XCTAssertEqual(Set(plan.writes.keys), ["Sources/Engine/AppleBridging.swift"])
    }

    func testFilesOutsideTheAppAreNeverTouched() throws {
        let current = [
            "Package.swift": manifest(),
            "Assets.xcassets/AppIcon.appiconset/Contents.json": bytes("icon"),
            ".swiftpm/playgrounds/state.plist": bytes("state"),
            "Sources/.hidden.swift": bytes("hidden"),
        ]
        let new = [
            "Package.swift": manifest(),
            "README.md": bytes("not the app"),
            "Sources/.DS_Store": bytes("finder"),
        ]
        let plan = try ProjectSync.plan(new: new, current: current)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(ProjectSync.isManaged("Assets.xcassets/Contents.json"))
        XCTAssertFalse(ProjectSync.isManaged("Sources/../Package.swift"))
        XCTAssertTrue(ProjectSync.isManaged("Sources/UI/Game/PlayScreen.swift"))
    }

    func testTheIconChosenInSwiftPlaygroundsStays() throws {
        let current = ["Package.swift": manifest(icon: ".asset(\"AppIcon\")", version: "1.1")]
        let new = ["Package.swift": manifest(version: "1.2")]
        let plan = try ProjectSync.plan(new: new, current: current)
        let written = String(decoding: try XCTUnwrap(plan.writes["Package.swift"]), as: UTF8.self)
        XCTAssertTrue(written.contains("appIcon: .asset(\"AppIcon\"),"))
        XCTAssertTrue(written.contains("displayVersion: \"1.2\""))
        // Just before the accent colour, where Swift Playgrounds puts it.
        let lines = written.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let icon = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("appIcon:") })
        XCTAssertTrue(lines[icon + 1].hasPrefix("accentColor:"))
    }

    /// Only the kept icon differs: the manifest is not rewritten at all.
    func testAManifestThatOnlyKeepsTheIconIsUnchanged() throws {
        let current = ["Package.swift": manifest(icon: ".asset(\"AppIcon\")")]
        let new = ["Package.swift": manifest()]
        let plan = try ProjectSync.plan(new: new, current: current)
        XCTAssertTrue(plan.isEmpty)
    }

    func testAnotherAppsProjectIsRefused() {
        let current = ["Package.swift": manifest(bundle: "com.ablox.studio")]
        let new = ["Package.swift": manifest(bundle: "com.ablox.client")]
        XCTAssertThrowsError(try ProjectSync.plan(new: new, current: current)) { error in
            XCTAssertEqual(error as? ProjectSync.Problem, .otherApp("com.ablox.studio"))
        }
    }

    func testAFolderWithoutAManifestIsRefused() {
        XCTAssertThrowsError(try ProjectSync.plan(new: ["Package.swift": manifest()], current: ["Sources/A.swift": bytes("a")])) { error in
            XCTAssertEqual(error as? ProjectSync.Problem, .notAProject)
        }
    }

    func testBundleIdentifierIsRead() {
        XCTAssertEqual(ProjectSync.bundleIdentifier(inManifest: String(decoding: manifest(), as: UTF8.self)), "com.ablox.client")
        XCTAssertNil(ProjectSync.bundleIdentifier(inManifest: "let package = Package(name: \"x\")"))
    }

    /// The real manifests of both apps, as they are in this repository.
    func testTheShippingManifestNamesItsApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifests = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "swiftpm" }
            .map { $0.appendingPathComponent("Package.swift") } ?? []
        XCTAssertFalse(manifests.isEmpty)
        for url in manifests {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNotNil(ProjectSync.bundleIdentifier(inManifest: text), url.path)
        }
    }
}
