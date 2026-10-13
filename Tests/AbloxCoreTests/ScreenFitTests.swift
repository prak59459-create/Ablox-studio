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
}
