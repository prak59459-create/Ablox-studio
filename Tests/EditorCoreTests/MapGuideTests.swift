import XCTest
@testable import AbloxCore

/// Keeps the map-making guide honest.
///
/// A guide is the one kind of code that fails silently: it keeps compiling,
/// keeps rendering, and simply becomes untrue. These are the checks CI can
/// actually make — that the guide covers everything the editor offers, names
/// nothing it does not, and matches the copy committed as `docs/making-maps.md`.
final class MapGuideTests: XCTestCase {

    // MARK: Coverage

    func testEveryBlockBehaviourIsExplained() {
        // Walked from allCases, not a hand-written list: adding a behaviour
        // fails here until someone writes a sentence for it.
        let text = MapGuide.sections.flatMap { $0.steps.map(\.text) }.joined(separator: "\n")
        for behaviour in BlockBehavior.allCases {
            XCTAssertTrue(
                text.contains(behaviour.displayName),
                "\(behaviour) is offered in the Inspector but the guide never mentions it"
            )
            XCTAssertFalse(behaviour.guidance.isEmpty, "\(behaviour) has no guidance sentence")
        }
    }

    func testEveryBehaviourGuidanceIsASentence() {
        for behaviour in BlockBehavior.allCases {
            let guidance = behaviour.guidance
            XCTAssertTrue(guidance.hasSuffix("."), "\(behaviour): \(guidance)")
            XCTAssertGreaterThan(guidance.count, 20, "\(behaviour)'s guidance says too little to help")
        }
    }

    func testEveryPalettePartIsExplained() {
        for kind in BlockData.PresetKind.allCases {
            XCTAssertFalse(kind.guidance.isEmpty, "\(kind) is in the palette with nothing said about it")
            XCTAssertTrue(kind.guidance.hasSuffix("."), "\(kind): \(kind.guidance)")
        }
    }

    func testPartGuidanceDescribesThePartThePresetActuallyBuilds() {
        // The trap this closes: writing "a tall pillar" for a preset someone
        // later changed to a cube. Checked against the preset itself, so the
        // description cannot outlive the thing it describes.
        let origin = Vec3.zero

        let spawn = BlockData.preset(.spawn, at: origin)
        XCTAssertEqual(spawn.behavior, .spawn)
        XCTAssertTrue(BlockData.PresetKind.spawn.guidance.lowercased().contains("start"))

        let orb = BlockData.preset(.orb, at: origin)
        XCTAssertEqual(orb.behavior, .collectible)
        XCTAssertTrue(
            BlockData.PresetKind.orb.guidance.contains("\(orb.scoreValue) points"),
            "the guide quotes a score the preset does not award"
        )

        let hazard = BlockData.preset(.hazard, at: origin)
        XCTAssertEqual(hazard.behavior, .hazard)

        let goal = BlockData.preset(.goal, at: origin)
        XCTAssertEqual(goal.behavior, .goal)

        let checkpoint = BlockData.preset(.checkpoint, at: origin)
        XCTAssertEqual(checkpoint.behavior, .checkpoint)

        // The three plain building parts must stay inert, or the guide's
        // "everyday building material" becomes a lie that bites at play time.
        for kind in [BlockData.PresetKind.block, .platform, .pillar, .ramp] {
            XCTAssertEqual(BlockData.preset(kind, at: origin).behavior, .none, "\(kind) is no longer plain scenery")
        }
    }

    func testTheRampIsActuallyTilted() {
        // "already tilted 25°, so players can walk up it" is a promise.
        let ramp = BlockData.preset(.ramp, at: .zero)
        XCTAssertNotEqual(ramp.transform.rotation, Quat.identity, "the guide calls the ramp tilted")
        XCTAssertTrue(BlockData.PresetKind.ramp.guidance.contains("25°"))
    }

    func testEveryToolIsNamed() {
        let text = MapGuide.sections.flatMap { $0.steps.map(\.text) }.joined(separator: "\n")
        for tool in EditorDocument.Tool.allCases {
            XCTAssertTrue(text.contains(tool.displayName), "the toolbar has \(tool.displayName) and the guide does not")
        }
    }

    // MARK: Accuracy

    func testTheGuideQuotesSnapValuesTheToolbarOffers() {
        // The toolbar's pickers are 0.25/0.5/1/2 m and 15/45/90°. Quoting a
        // value that is not on the menu sends someone looking for it.
        let text = MapGuide.sections.flatMap { $0.steps.map(\.text) }.joined(separator: "\n")
        for value in ["0.25", "0.5", "1 or 2 metres", "15°", "45°", "90°"] {
            XCTAssertTrue(text.contains(value), "the guide should name the snap setting \(value)")
        }
    }

    func testTheGuideQuotesTheBounceRangeTheInspectorAllows() {
        // InspectorPanel's slider is 6...30 and GimmickSettings starts at 14.
        let text = MapGuide.sections.flatMap { $0.steps.map(\.text) }.joined(separator: "\n")
        let defaults = GimmickSettings()
        XCTAssertEqual(defaults.bounceSpeed, 14, "the guide says bouncy starts at 14")
        XCTAssertTrue(text.contains("6 to 30"))
        XCTAssertTrue(text.contains("starts at 14"))
    }

    func testTheGuideDoesNotPromiseASaveButton() {
        // There is no Save button — saving is automatic, on Play, and on exit.
        // This was wrong in the first draft, which is why it is asserted.
        let text = MapGuide.sections.flatMap { $0.steps.map(\.text) }.joined(separator: " ")
        XCTAssertFalse(text.contains("Save button") && !text.contains("no Save button"))
    }

    // MARK: Shape

    func testSectionsAreUsable() {
        XCTAssertGreaterThanOrEqual(MapGuide.sections.count, 8)
        for section in MapGuide.sections {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.summary.isEmpty)
            XCTAssertFalse(section.symbolName.isEmpty)
            XCTAssertFalse(section.steps.isEmpty, "\(section.title) is a heading with nothing under it")
            for step in section.steps {
                XCTAssertFalse(step.text.isEmpty)
                XCTAssertNotEqual(step.aside, "", "an empty aside renders as a stray bullet")
            }
        }
    }

    func testSectionTitlesAreDistinct() {
        let titles = MapGuide.sections.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    // MARK: The committed document

    func testTheMarkdownFileMatchesTheGuide() throws {
        // docs/making-maps.md is generated, not written. If this fails, run
        // the guide's `markdown` output into that file again — do not edit the
        // Markdown, because Studio shows the Swift version and would then be
        // showing something different from what the repository documents.
        let url = repositoryRoot().appendingPathComponent("docs/making-maps.md")
        let onDisk = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(
            onDisk, MapGuide.markdown,
            "docs/making-maps.md has drifted from MapGuide.markdown"
        )
    }

    func testTheJapaneseMarkdownFileMatchesTheGuide() throws {
        // The Japanese guide in Studio and docs/making-maps.ja.md come from the
        // same call with the language switched, so this failing means one of
        // them is stale — and the app's copy is the one nobody would notice.
        Localization.language = .japanese
        defer { Localization.language = .english }

        let url = repositoryRoot().appendingPathComponent("docs/making-maps.ja.md")
        let onDisk = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(onDisk, MapGuide.markdown, "docs/making-maps.ja.md has drifted; run scripts/regenerate-docs.sh")
    }

    func testTheWholeGuideIsTranslated() throws {
        // Walks the rendered Japanese guide and fails on any line still in
        // English. A half-translated guide is the failure this catches: it
        // compiles, it renders, and it reads as unfinished.
        Localization.language = .japanese
        defer { Localization.language = .english }

        for section in MapGuide.sections {
            assertJapanese(section.title, "a section title")
            assertJapanese(section.summary, "a section summary")
            for step in section.steps {
                assertJapanese(step.text, "a step")
                if let aside = step.aside { assertJapanese(aside, "an aside") }
            }
        }
    }

    private func assertJapanese(
        _ text: String,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hasJapanese = text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        XCTAssertTrue(hasJapanese, "\(what) is still English: \(text)", file: file, line: line)
    }

    func testTheMarkdownRendersAsidesUnderTheirStep() {
        let markdown = MapGuide.markdown
        XCTAssertTrue(markdown.hasPrefix("# Making a map in Ablox Studio"))
        for section in MapGuide.sections {
            XCTAssertTrue(markdown.contains("## "), "sections need headings")
            XCTAssertTrue(markdown.contains(section.summary))
        }
        // An aside is indented under its bullet; at the same level it reads as
        // a separate instruction rather than a footnote to one.
        XCTAssertTrue(markdown.contains("\n  - *"))
    }

    /// The repository root, found from this file rather than the working
    /// directory, which differs between `swift test` and Xcode.
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // Tests/EditorCoreTests/MapGuideTests.swift
            .deletingLastPathComponent()    // Tests/EditorCoreTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo>
    }
}
