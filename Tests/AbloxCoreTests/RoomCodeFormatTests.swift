import XCTest
@testable import AbloxCore

/// The room code, and the on-screen pad that lets someone type one on an iPad
/// whose keyboard never appears.
final class RoomCodeFormatTests: XCTestCase {

    // MARK: The alphabet

    func testTheAlphabetLeavesOutLookalikes() {
        // A code read aloud across a table must not be mistypable into a
        // different valid code.
        for character in "ILOU01" {
            XCTAssertFalse(RoomCodeFormat.alphabet.contains(character), "\(character) is too easy to misread")
        }
        XCTAssertEqual(RoomCodeFormat.alphabet.count, 30)
        XCTAssertEqual(Set(RoomCodeFormat.alphabet).count, 30, "no duplicates")
    }

    func testNormalisingAcceptsHowPeopleActuallyTypeIt() {
        XCTAssertEqual(RoomCodeFormat.normalize("abc def"), "ABCDEF")
        XCTAssertEqual(RoomCodeFormat.normalize("ABC-DEF"), "ABCDEF")
        XCTAssertEqual(RoomCodeFormat.normalize("  abcdef \n"), "ABCDEF")
    }

    func testFormattingGroupsTheCode() {
        XCTAssertEqual(RoomCodeFormat.formatted("abcdef"), "ABC DEF")
        XCTAssertEqual(RoomCodeFormat.formatted("abc"), "ABC")
    }

    func testFormattingAndNormalisingRoundTrip() {
        // The join field shows the formatted code and stores the normalised
        // one. Typing into it goes through both, so they have to agree or the
        // space would be doubled or the cursor would jump.
        for raw in ["ABCDEF", "abc def", "A", "", "ABCDEFGH"] {
            let shown = RoomCodeFormat.formatted(raw)
            XCTAssertEqual(RoomCodeFormat.normalize(shown), RoomCodeFormat.normalize(raw))
        }
    }

    // MARK: The pad

    func testThePadHasEveryCharacterExactlyOnce() {
        let keys = RoomCodeFormat.padRows.flatMap { $0 }
        XCTAssertEqual(keys.count, RoomCodeFormat.alphabet.count)
        XCTAssertEqual(Set(keys), Set(RoomCodeFormat.alphabet))
    }

    func testThePadIsAGridOfSix() {
        // The code length, so the pad reads as a grid rather than a keyboard.
        for row in RoomCodeFormat.padRows {
            XCTAssertEqual(row.count, 6)
        }
    }

    func testTypingBuildsACode() {
        var code = ""
        for key in "ABC234" {
            code = RoomCodeFormat.typing(key, into: code)
        }
        XCTAssertEqual(code, "ABC234")
        XCTAssertTrue(RoomCodeFormat.isPlausible(code))
    }

    func testTypingStopsAtTheCodeLength() {
        var code = "ABCDEF"
        code = RoomCodeFormat.typing("G", into: code)
        XCTAssertEqual(code, "ABCDEF", "a seventh character would make every code wrong")
    }

    func testTheCodeLengthMatchesWhatHostsGenerate() {
        // If these drifted apart, the pad would refuse the last character of
        // every real code.
        XCTAssertEqual(RoomCodeFormat.length, 6)
    }

    func testAKeyNotInTheAlphabetDoesNothing() {
        XCTAssertEqual(RoomCodeFormat.typing("O", into: "AB"), "AB")
        XCTAssertEqual(RoomCodeFormat.typing("!", into: "AB"), "AB")
    }

    func testDeletingRemovesOneCharacter() {
        XCTAssertEqual(RoomCodeFormat.deleting(from: "ABC"), "AB")
        XCTAssertEqual(RoomCodeFormat.deleting(from: ""), "", "deleting from nothing is not a crash")
    }

    func testThePadAndAHardwareKeyboardAgree() {
        // The same field takes both. A hardware keyboard can type anything,
        // including a space from the formatted display; the pad has to carry
        // on from the cleaned-up value rather than from the raw text.
        let fromKeyboard = "abc d"
        XCTAssertEqual(RoomCodeFormat.typing("E", into: fromKeyboard), "ABCDE")
        XCTAssertEqual(RoomCodeFormat.deleting(from: "ABC D"), "ABC")
    }

    func testTheHintOnlyNamesCharactersThatAreReallyMissing() {
        // The pad tells people which characters codes never use. The first
        // version said "type 0 or 1 instead of O or I" — but 0 and 1 are left
        // out too, so it sent people hunting for keys that do not exist. This
        // test is what caught it.
        for character in RoomCodeFormat.neverUsed {
            XCTAssertFalse(RoomCodeFormat.alphabet.contains(character), "\(character) is on the pad after all")
        }
    }

    func testEveryExcludedCharacterIsNamedInTheHint() {
        // The reverse: a character missing from the pad but not named would
        // leave someone searching for it.
        let everyone = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let missing = everyone.subtracting(RoomCodeFormat.alphabet)
        XCTAssertEqual(missing, Set(RoomCodeFormat.neverUsed))
    }
}
