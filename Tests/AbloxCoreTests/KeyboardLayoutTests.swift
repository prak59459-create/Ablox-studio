import XCTest
@testable import AbloxCore

final class KeyboardLayoutTests: XCTestCase {

    func testTheKanaChartHasEveryBasicKanaOnce() {
        let keys = KeyboardKeys.kana.flatMap { $0 }
        let basics = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"
        for kana in basics {
            XCTAssertEqual(keys.filter { $0 == String(kana) }.count, 1, "\(kana)")
        }
        XCTAssertTrue(KeyboardKeys.kana.allSatisfy { $0.count == 10 })
        XCTAssertEqual(KeyboardKeys.kana[0].last, "あ", "あ sits on the right, as on the poster")
    }

    func testLetterAndSymbolRowsHaveNoRepeats() {
        for rows in [KeyboardKeys.letters, KeyboardKeys.symbols, KeyboardKeys.kana] {
            for row in rows {
                XCTAssertEqual(Set(row).count, row.count, row.joined())
            }
        }
        XCTAssertEqual(KeyboardKeys.letters.flatMap { $0 }.count, 26)
    }

    func testVoicingCyclesLikeAPhoneKeyboard() {
        XCTAssertEqual(KanaInput.voiced("か"), "が")
        XCTAssertEqual(KanaInput.voiced("が"), "か")
        XCTAssertEqual(KanaInput.voiced("は"), "ば")
        XCTAssertEqual(KanaInput.voiced("ば"), "ぱ")
        XCTAssertEqual(KanaInput.voiced("ぱ"), "は")
        XCTAssertEqual(KanaInput.voiced("う"), "ゔ")
        XCTAssertEqual(KanaInput.voiced("ハ"), "バ", "katakana stays katakana")
        XCTAssertNil(KanaInput.voiced("あ"))
        XCTAssertNil(KanaInput.voiced("a"))
    }

    func testSmallKanaGoBothWays() {
        XCTAssertEqual(KanaInput.small("つ"), "っ")
        XCTAssertEqual(KanaInput.small("っ"), "つ")
        XCTAssertEqual(KanaInput.small("よ"), "ょ")
        XCTAssertEqual(KanaInput.small("ヤ"), "ャ")
        XCTAssertNil(KanaInput.small("か"))
    }

    func testKatakanaConversion() {
        XCTAssertEqual(KanaInput.katakana("ねこ"), "ネコ")
        XCTAssertEqual(KanaInput.katakana("ー、a1"), "ー、a1", "marks and letters pass through")
        XCTAssertEqual(KanaInput.hiragana("ネ"), "ね")
    }
}
