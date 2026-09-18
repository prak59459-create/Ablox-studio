import XCTest
@testable import AbloxCore

final class AbloxIconTests: XCTestCase {

    func testVocabularyMatchesTheIconSheet() {
        // The sheet lists 240 labels across six sections of 40, of which 8
        // names repeat across sections (trophy, medal, crown, diamond, rocket,
        // gift, key, keyboard) — so 232 distinct icons. A change to this count
        // means the sheet and the code have diverged.
        XCTAssertEqual(AbloxIcon.allCases.count, 232)
    }

    func testNamesAreUnique() {
        // Raw values are the sheet's own names. A duplicate would not compile,
        // but the camel-cased case names could still collide in review, so
        // assert it rather than assume it.
        let names = AbloxIcon.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testEveryIconResolvesToADrawableSymbol() {
        // The whole point of the registry: a view can never end up with an
        // empty or nil symbol name and render an invisible glyph.
        for icon in AbloxIcon.allCases {
            XCTAssertFalse(icon.symbolName.isEmpty, "\(icon.rawValue) has no symbol")
            XCTAssertFalse(
                icon.symbolName.hasPrefix("."),
                "\(icon.rawValue) maps to \"\(icon.symbolName)\", which is not a symbol name"
            )
            XCTAssertFalse(
                icon.symbolName.contains(" "),
                "\(icon.rawValue) maps to \"\(icon.symbolName)\", which contains a space"
            )
        }
    }

    func testNamesAreKebabCase() {
        // The sheet's convention. Keeping to it means a future asset bundle can
        // be keyed on `rawValue` with no translation step.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for icon in AbloxIcon.allCases {
            XCTAssertTrue(
                icon.rawValue.unicodeScalars.allSatisfy(allowed.contains),
                "\(icon.rawValue) is not kebab-case"
            )
            XCTAssertFalse(icon.rawValue.hasPrefix("-"))
            XCTAssertFalse(icon.rawValue.hasSuffix("-"))
        }
    }

    func testLookupByNameRoundTrips() {
        for icon in AbloxIcon.allCases {
            XCTAssertEqual(AbloxIcon(rawValue: icon.rawValue), icon)
        }
        XCTAssertNil(AbloxIcon(rawValue: "not-an-icon"))
    }

    // MARK: Stand-ins

    func testStandInListIsConsistent() {
        // `standInIcons` is hand-maintained, so guard against it naming an
        // icon twice or drifting from `needingCustomArtwork`.
        XCTAssertEqual(
            Set(AbloxIcon.needingCustomArtwork),
            AbloxIcon.standInIcons
        )
        XCTAssertFalse(AbloxIcon.standInIcons.isEmpty)
    }

    func testStandInsAreAMinorityOfTheVocabulary() {
        // If most of the set needed custom art, leaning on SF Symbols would be
        // the wrong call and this test should fail to say so.
        let ratio = Double(AbloxIcon.standInIcons.count) / Double(AbloxIcon.allCases.count)
        XCTAssertLessThan(ratio, 0.35, "too much of the vocabulary is approximated")
    }

    func testBrandMarksAreMarkedAsStandIns() {
        // SF Symbols will never ship a YouTube or Discord glyph, so these must
        // never be quietly presented as native.
        for icon in [AbloxIcon.youtube, .twitch, .discord, .spotify] {
            XCTAssertFalse(icon.hasNativeEquivalent, "\(icon.rawValue) is a brand mark")
        }
    }

    func testCommonIconsAreNative() {
        // The everyday vocabulary should not be approximated — if one of these
        // ends up a stand-in, something has gone wrong in the mapping.
        for icon in [AbloxIcon.person, .heart, .star, .close, .check, .search, .trash, .gearCog] {
            XCTAssertTrue(icon.hasNativeEquivalent, "\(icon.rawValue) should have a real symbol")
        }
    }

    // MARK: Icons the apps actually use

    /// Every icon referenced by the shipping UI.
    ///
    /// Listing them here is what turns the registry from a catalogue into a
    /// contract: renaming or deleting an icon the UI depends on fails this
    /// test rather than leaving a blank square on someone's iPad.
    private static let inUse: [AbloxIcon] = [
        // Menu and lobby
        .gamepad, .stack, .person, .gearCog, .close, .check, .plus, .search,
        .trash, .grid, .list, .chevronDown, .chevronRight, .moreHorizontal,
        // Session and networking
        .lock, .wifi, .globe, .friends, .group, .message, .chatBubble,
        // Gameplay.
        // Note `coin` is deliberately absent: the collectible in the starter
        // world renders as `orb`, and the nearest symbol for a coin is a
        // dollar sign, which is a currency rather than a game token. It stays
        // in the vocabulary as a candidate for custom artwork.
        .trophy, .star, .flag, .heart, .crown, .medal, .flame,
        .shield, .target, .touch, .arrowUp,
        // Studio
        .hammer, .wrench, .layers, .box, .gift, .key, .eye, .eyeOff,
        .arrowDown, .magicWand, .sparkle, .warning, .success, .info,
    ]

    func testIconsUsedByTheUIAllExist() {
        for icon in Self.inUse {
            XCTAssertTrue(
                AbloxIcon.allCases.contains(icon),
                "\(icon.rawValue) is referenced by the UI but missing from the vocabulary"
            )
            XCTAssertFalse(icon.symbolName.isEmpty)
        }
    }

    func testIconsUsedByTheUIAreNotApproximations() {
        // Anything the shipping UI leans on should be a real symbol. A stand-in
        // here is a visible compromise on a screen someone actually sees.
        let approximated = Self.inUse.filter { !$0.hasNativeEquivalent }
        XCTAssertTrue(
            approximated.isEmpty,
            "UI depends on approximated icons: \(approximated.map(\.rawValue).joined(separator: ", "))"
        )
    }
}
