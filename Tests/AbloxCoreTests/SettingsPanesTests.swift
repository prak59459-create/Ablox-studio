import XCTest
@testable import AbloxCore

/// Settings in groups down the side, like a Mac's System Settings.
final class SettingsPanesTests: XCTestCase {

    func testEveryCardIsInExactlyOneGroup() {
        let listed = SettingsPane.allCases.flatMap(\.cards)
        XCTAssertEqual(listed.count, SettingsCard.allCases.count)
        XCTAssertEqual(Set(listed), Set(SettingsCard.allCases))
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.cards.isEmpty, "\(pane) has no cards")
            for card in pane.cards { XCTAssertEqual(SettingsPane.pane(of: card), pane) }
        }
    }

    func testWithoutASearchTheGroupsCardsAreShown() {
        XCTAssertEqual(SettingsPane.shown(pane: .sound, search: ""), [.soundLibrary, .myMusic])
        XCTAssertEqual(SettingsPane.shown(pane: .general, search: "   ").first, .language)
        XCTAssertTrue(SettingsPane.matching("").isEmpty)
    }

    func testASearchLooksThroughEveryGroup() {
        let found = SettingsPane.shown(pane: .general, search: "backup")
        XCTAssertEqual(found, [.data])
        XCTAssertEqual(SettingsPane.matching("backup"), [.data])
        XCTAssertTrue(SettingsPane.shown(pane: .general, search: "zzzz").isEmpty)
        XCTAssertTrue(SettingsPane.shown(pane: .general, search: "joystick").contains(.controls))
    }

    func testGroupsHaveTheirOwnLooks() {
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.symbol)).count, SettingsPane.allCases.count)
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.title)).count, SettingsPane.allCases.count)
    }
}
