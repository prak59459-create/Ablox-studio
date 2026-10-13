import XCTest
@testable import AbloxCore

/// The compact layout for an iPhone (and a small iPad window).
final class ScreenFitTests: XCTestCase {

    func testIPadsKeepTheIPadLayout() {
        // iPad mini in portrait, the smallest full-screen iPad window, and a
        // 13-inch iPad in landscape.
        for fit in [ScreenFit(width: 744, height: 1133), ScreenFit(width: 1366, height: 1024)] {
            XCTAssertFalse(fit.isCompact)
            XCTAssertEqual(fit.sidebarWidth, 264)
            XCTAssertTrue(fit.showsTabNames)
            XCTAssertEqual(fit.sidePanel(420), 420)
            XCTAssertEqual(fit.square(520), 520)
        }
    }

    func testIPhonesGetTheCompactLayout() {
        // An iPhone in landscape and in portrait.
        for fit in [ScreenFit(width: 932, height: 430), ScreenFit(width: 390, height: 844)] {
            XCTAssertTrue(fit.isCompact)
            XCTAssertFalse(fit.showsTabNames)
            XCTAssertLessThan(fit.sidebarWidth, 100)
            XCTAssertLessThan(fit.gutter, 28)
        }
    }

    func testPanelsAndTheMapFitOnAPhone() {
        let landscape = ScreenFit(width: 844, height: 390)
        // The avatar editor leaves more than half the screen for the avatar.
        XCTAssertLessThanOrEqual(landscape.sidePanel(420), 844 * 0.45)
        // A narrow panel stays as drawn.
        XCTAssertEqual(landscape.sidePanel(250), 250)
        // The big map fits inside the height with a margin.
        XCTAssertEqual(landscape.square(520), 390 - 48)

        let portrait = ScreenFit(width: 375, height: 667)
        XCTAssertGreaterThanOrEqual(portrait.sidePanel(420), 200)
        XCTAssertLessThanOrEqual(portrait.square(520), 375)
    }

    func testNoNegativeSizes() {
        let fit = ScreenFit(width: -10, height: 0)
        XCTAssertTrue(fit.isCompact)
        XCTAssertGreaterThan(fit.square(520), 0)
        XCTAssertGreaterThan(fit.sidePanel(420), 0)
    }

    func testCardGridsFitOneColumnOnAPhone() {
        // An iPad keeps the card sizes the menus were drawn with.
        let iPad = ScreenFit(width: 744, height: 1133)
        XCTAssertEqual(iPad.cardMinimum(280), 280)
        XCTAssertEqual(iPad.cardMinimum(240), 240)

        // The smallest iPhone in portrait: a card is never wider than the
        // page beside the icons-only sidebar.
        let small = ScreenFit(width: 320, height: 568)
        let page = small.width - small.sidebarWidth - small.gutter * 2
        for preferred in [170.0, 230, 240, 260, 280] {
            XCTAssertLessThanOrEqual(small.cardMinimum(preferred), page)
            XCTAssertGreaterThanOrEqual(small.cardMinimum(preferred), 140)
        }

        // A phone in landscape has room for the cards as drawn.
        XCTAssertEqual(ScreenFit(width: 844, height: 390).cardMinimum(280), 280)
    }

    func testPlayButtonsAndCornerMapFitAPhoneHeldSideways() {
        // An iPad keeps the play screen as drawn.
        let iPad = ScreenFit(width: 1180, height: 820)
        XCTAssertEqual(iPad.controlScale, 1)
        XCTAssertEqual(iPad.controlInset(44), 44)
        XCTAssertEqual(iPad.controlInset(150), 150)
        XCTAssertEqual(iPad.cornerMap(240), 240)

        // An iPhone in landscape: below the chips at the top (64 points) the
        // corner map and the jump button with its extra buttons both fit.
        let phone = ScreenFit(width: 844, height: 390)
        XCTAssertLessThan(phone.controlScale, 1)
        XCTAssertLessThanOrEqual(phone.cornerMap(MapSize.large.points), 390 * 0.3)
        XCTAssertGreaterThanOrEqual(phone.cornerMap(MapSize.small.points), 90)
        XCTAssertLessThan(phone.controlInset(150), 150)
        XCTAssertGreaterThanOrEqual(phone.controlInset(44), 12)
        // The one-handed layout still leaves room for the buttons.
        XCTAssertLessThan(phone.controlInset(150) * 2, phone.height / 2)

        // A phone in portrait keeps its buttons at full size.
        XCTAssertEqual(ScreenFit(width: 390, height: 844).controlScale, 1)
    }
}
