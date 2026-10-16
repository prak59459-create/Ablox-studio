import XCTest
@testable import AbloxCore

/// Studio's three levels: what each shows, and that going between them loses nothing.
final class StudioLevelTests: XCTestCase {

    func testEachLevelShowsMoreThanTheOneBelow() {
        XCTAssertEqual(StudioLevel.easy.tools, [.select, .move, .paint])
        XCTAssertTrue(Set(StudioLevel.easy.tools).isSubset(of: Set(StudioLevel.normal.tools)))
        XCTAssertTrue(Set(StudioLevel.normal.tools).isSubset(of: Set(StudioLevel.pro.tools)))
        XCTAssertEqual(StudioLevel.pro.tools, EditorDocument.Tool.allCases)
        XCTAssertFalse(StudioLevel.normal.allows(.terrain))
        XCTAssertTrue(StudioLevel.pro.allows(.terrain))
    }

    func testEasyPutsTheRulesScriptsAndSnappingAway() {
        let easy = StudioLevel.easy
        XCTAssertFalse(easy.showsRules)
        XCTAssertFalse(easy.showsScripts)
        XCTAssertFalse(easy.showsSnapping)
        XCTAssertEqual(easy.fixedGrid, 1)
        XCTAssertEqual(easy.fixedAngle, 90)
        XCTAssertTrue(StudioLevel.normal.showsRules)
        XCTAssertFalse(StudioLevel.normal.showsScripts)
        XCTAssertNil(StudioLevel.normal.fixedGrid)
        XCTAssertTrue(StudioLevel.pro.showsScripts)
    }

    func testAToolPutAwayFallsBackToPicking() {
        XCTAssertEqual(StudioLevel.easy.tool(replacing: .terrain), .select)
        XCTAssertEqual(StudioLevel.easy.tool(replacing: .paint), .paint)
        XCTAssertEqual(StudioLevel.normal.tool(replacing: .terrain), .select)
        XCTAssertEqual(StudioLevel.pro.tool(replacing: .terrain), .terrain)
    }

    func testAnUnknownOrMissingChoiceKeepsEverything() {
        XCTAssertEqual(StudioLevel(stored: nil), .pro)
        XCTAssertEqual(StudioLevel(stored: "expert"), .pro)
        XCTAssertEqual(StudioLevel(stored: "easy"), .easy)
    }

    func testEveryLevelHasWordsInBothLanguages() {
        for key in ["Easy", "Normal", "Pro"] { XCTAssertNotNil(Strings.japanese[key], key) }
        for level in StudioLevel.allCases { XCTAssertNotNil(Strings.japanese[level.detail], level.detail) }
    }
}
