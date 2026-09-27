import Foundation

// The keys of Ablox's own on-screen keyboard, and the kana rules behind it.
//
// Some iPads never show the system keyboard inside the app — an attached
// keyboard case, a Swift Playgrounds quirk, an older iPad — and a child who
// cannot type cannot chat, name their avatar or write a script. So both apps
// carry a keyboard of their own, drawn like any other part of the screen.
// The layouts and the kana conversions are plain data, tested here; the
// drawing is `AbloxKeyboard.swift`.

/// Which page of keys is showing.
public enum KeyboardPage: String, CaseIterable, Sendable {
    case letters, kana, symbols
}

public enum KeyboardKeys {

    public static let letters: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"]
    ]

    public static let symbols: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "&", "@", "\"", "'"],
        [".", ",", "?", "!", "_", "#", "%", "+", "=", "*"],
        ["[", "]", "{", "}", "<", ">", "~", "|", "\\", "$"]
    ]

    /// The kana chart as children learn it from the poster: one column per
    /// consonant, あ on the right, read top to bottom. Gaps in the や and わ
    /// columns hold brackets and marks so no key is wasted.
    public static let kanaColumns: [[String]] = [
        ["わ", "を", "ん", "ー", "〜"],
        ["ら", "り", "る", "れ", "ろ"],
        ["や", "「", "ゆ", "」", "よ"],
        ["ま", "み", "む", "め", "も"],
        ["は", "ひ", "ふ", "へ", "ほ"],
        ["な", "に", "ぬ", "ね", "の"],
        ["た", "ち", "つ", "て", "と"],
        ["さ", "し", "す", "せ", "そ"],
        ["か", "き", "く", "け", "こ"],
        ["あ", "い", "う", "え", "お"]
    ]

    /// The same chart as rows, left to right, for drawing.
    public static var kana: [[String]] {
        (0..<5).map { row in kanaColumns.map { $0[row] } }
    }

    /// Marks at the end of the kana page.
    public static let kanaMarks = ["、", "。", "！", "？", "・"]
}

/// Changing the character just typed — the way a phone keyboard's ゛゜ and
/// 小 keys work — and switching between hiragana and katakana.
public enum KanaInput {

    /// か → が → か, は → ば → ぱ → は, う → ゔ → う. Katakana too.
    public static func voiced(_ character: Character) -> Character? {
        let hira = hiragana(character)
        guard let next = voicing[hira] else { return nil }
        return isKatakana(character) ? katakana(next) : next
    }

    /// つ ↔ っ, や ↔ ゃ, あ ↔ ぁ and the rest. Katakana too.
    public static func small(_ character: Character) -> Character? {
        let hira = hiragana(character)
        guard let next = smalls[hira] else { return nil }
        return isKatakana(character) ? katakana(next) : next
    }

    public static func katakana(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (0x3041...0x3096).contains(scalar.value),
              let shifted = Unicode.Scalar(scalar.value + 0x60) else { return character }
        return Character(shifted)
    }

    public static func hiragana(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (0x30A1...0x30F6).contains(scalar.value),
              let shifted = Unicode.Scalar(scalar.value - 0x60) else { return character }
        return Character(shifted)
    }

    public static func katakana(_ text: String) -> String {
        String(text.map { katakana($0) })
    }

    static func isKatakana(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (0x30A1...0x30F6).contains(scalar.value)
    }

    private static let voicing: [Character: Character] = {
        var map: [Character: Character] = [:]
        // Plain ↔ voiced pairs.
        let pairs: [(Character, Character)] = [
            ("か", "が"), ("き", "ぎ"), ("く", "ぐ"), ("け", "げ"), ("こ", "ご"),
            ("さ", "ざ"), ("し", "じ"), ("す", "ず"), ("せ", "ぜ"), ("そ", "ぞ"),
            ("た", "だ"), ("ち", "ぢ"), ("つ", "づ"), ("て", "で"), ("と", "ど"),
            ("う", "ゔ")
        ]
        for (plain, voiced) in pairs {
            map[plain] = voiced
            map[voiced] = plain
        }
        // は → ば → ぱ → は.
        let rows: [(Character, Character, Character)] = [
            ("は", "ば", "ぱ"), ("ひ", "び", "ぴ"), ("ふ", "ぶ", "ぷ"), ("へ", "べ", "ぺ"), ("ほ", "ぼ", "ぽ")
        ]
        for (plain, voiced, half) in rows {
            map[plain] = voiced
            map[voiced] = half
            map[half] = plain
        }
        // A small っ takes a mark the way つ does.
        map["っ"] = "づ"
        return map
    }()

    private static let smalls: [Character: Character] = {
        var map: [Character: Character] = [:]
        let pairs: [(Character, Character)] = [
            ("あ", "ぁ"), ("い", "ぃ"), ("う", "ぅ"), ("え", "ぇ"), ("お", "ぉ"),
            ("つ", "っ"), ("や", "ゃ"), ("ゆ", "ゅ"), ("よ", "ょ"), ("わ", "ゎ")
        ]
        for (big, little) in pairs {
            map[big] = little
            map[little] = big
        }
        return map
    }()
}
