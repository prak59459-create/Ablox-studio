import XCTest
@testable import AbloxCore

/// The translation table, which is the one place a mistake is silent.
///
/// A missing entry does not crash and does not fail to compile — it shows one
/// English line in a Japanese screen, and nobody reports it. So everything
/// checkable is checked here: no duplicate keys, no empty values, matching
/// placeholders, and no translation that is accidentally still English.
final class LocalizationTests: XCTestCase {

    override func tearDown() {
        Localization.language = .english
        super.tearDown()
    }

    // MARK: Table integrity

    func testNoKeyIsDefinedTwice() {
        // The reason `entries` is an array of pairs rather than a dictionary
        // literal: a repeated key in a literal is a runtime crash, and this
        // table is far too long to trust to eyes. Here it is a test failure.
        var seen: [String: Int] = [:]
        for (key, _) in Strings.entries {
            seen[key, default: 0] += 1
        }
        let duplicates = seen.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(duplicates.isEmpty, "defined more than once: \(duplicates)")
        XCTAssertEqual(Strings.japanese.count, Strings.entries.count)
    }

    func testNoEntryIsEmpty() {
        for (key, value) in Strings.entries {
            XCTAssertFalse(key.isEmpty, "an empty key can never be looked up")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) has no translation")
        }
    }

    func testEveryTranslationActuallyDiffersFromTheEnglish() {
        // A copy-paste that never got translated looks finished in the diff
        // and ships as English. The exceptions are strings that are genuinely
        // the same in both.
        let sameInBothLanguages: Set<String> = [
            "OK",
            "{}ms",
            "coin, trap, door…",
            "{} — {}"
        ]
        for (key, value) in Strings.entries where !sameInBothLanguages.contains(key) {
            XCTAssertNotEqual(key, value, "\"\(key)\" was never translated")
        }
    }

    func testPlaceholderCountsMatch() {
        // A translation that drops a `{}` silently loses the number or name it
        // was meant to show; one that adds a `{}` prints a literal "{}".
        for (key, value) in Strings.entries {
            XCTAssertEqual(
                Localization.placeholderCount(in: key),
                Localization.placeholderCount(in: value),
                "\"\(key)\" and its translation disagree on how many values they take"
            )
        }
    }

    func testJapaneseEntriesContainJapanese() {
        // Catches a row where the translation column was filled with a second
        // English string — which `testEveryTranslationActuallyDiffersFromTheEnglish`
        // would pass.
        let sameInBothLanguages: Set<String> = ["OK", "{}ms", "coin, trap, door…", "{} — {}", "English"]
        for (key, value) in Strings.entries where !sameInBothLanguages.contains(key) {
            let hasJapanese = value.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value) ||   // kana
                (0x4E00...0x9FFF).contains(scalar.value) ||   // kanji
                (0xFF00...0xFFEF).contains(scalar.value)      // full-width forms
            }
            XCTAssertTrue(hasJapanese, "\"\(key)\" is translated to \"\(value)\", which has no Japanese in it")
        }
    }

    // MARK: Lookup

    func testEnglishReturnsTheKeyUntouched() {
        Localization.language = .english
        XCTAssertEqual(L("Play"), "Play")
        XCTAssertEqual(L("a string nobody translated"), "a string nobody translated")
    }

    func testJapaneseReturnsTheTranslation() {
        Localization.language = .japanese
        XCTAssertEqual(L("Play"), "プレイ")
        XCTAssertEqual(L("Settings"), "設定")
    }

    func testAnUnknownStringFallsBackToEnglishRatherThanAKey() {
        // The deliberate failure mode. An untranslated line is unpolished; a
        // raw key on screen is a bug report.
        Localization.language = .japanese
        XCTAssertEqual(L("nothing in the table says this"), "nothing in the table says this")
    }

    // MARK: Placeholders

    func testPlaceholdersAreFilledInOrder() {
        Localization.language = .english
        XCTAssertEqual(L("Hosted by {}", "Mika"), "Hosted by Mika")
        XCTAssertEqual(Localization.fill("{} of {}", with: [2, 5]), "2 of 5")
    }

    func testPlaceholdersWorkInJapaneseToo() {
        Localization.language = .japanese
        XCTAssertEqual(L("Hosted by {}", "Mika"), "ホスト: Mika")
        XCTAssertEqual(L("{} editing", 3), "3人が編集中")
    }

    func testIntegersAndStringsBothSubstitute() {
        XCTAssertEqual(Localization.fill("{}ms", with: [42]), "42ms")
        XCTAssertEqual(Localization.fill("{}ms", with: ["42"]), "42ms")
    }

    func testAMissingArgumentLeavesTheHoleRatherThanCrashing() {
        // Should never happen — the counts are asserted above — but a
        // formatting slip must not take the app down in someone's hands.
        XCTAssertEqual(Localization.fill("{} of {}", with: [1]), "1 of {}")
    }

    func testExtraArgumentsAreIgnored() {
        XCTAssertEqual(Localization.fill("just {}", with: [1, 2, 3]), "just 1")
    }

    func testAStringWithNoPlaceholdersIsUnchanged() {
        XCTAssertEqual(Localization.fill("Play", with: ["ignored"]), "Play")
        XCTAssertEqual(Localization.fill("100% sure", with: []), "100% sure")
    }

    func testPercentSignsAreNotFormatDirectives() {
        // The reason `{}` was chosen over `%@`: `String(format:)` treats these
        // differently on Linux and on Apple platforms, and a stray percent in
        // a translation would be a crash rather than a wrong character.
        XCTAssertEqual(Localization.fill("50% of {}", with: ["them"]), "50% of them")
    }

    // MARK: Preference resolution

    func testExplicitChoicesIgnoreTheDevice() {
        XCTAssertEqual(LanguagePreference.english.language(preferredCodes: ["ja-JP"]), .english)
        XCTAssertEqual(LanguagePreference.japanese.language(preferredCodes: ["en-US"]), .japanese)
    }

    func testSystemFollowsTheDevice() {
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["en-GB"]), .english)
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["ja"]), .japanese)
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["ja_JP"]), .japanese)
    }

    func testSystemFallsBackToEnglishForALanguageWeDoNotHave() {
        // A Korean iPad gets English rather than nothing.
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["ko-KR"]), .english)
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: []), .english)
    }

    func testAPrefixMatchDoesNotCatchTheWrongLanguage() {
        // "ja" must not match "jam" or "java" — a real trap in code that uses
        // hasPrefix on a bare two-letter code.
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["jam"]), .english)
        XCTAssertEqual(LanguagePreference.system.language(preferredCodes: ["jv-ID"]), .english)
    }

    // MARK: What a screen actually shows

    func testTheBlockVocabularyChangesLanguage() {
        // These are not loose strings — they are what the Inspector's pickers
        // draw. If they stayed English, switching the language would visibly
        // do nothing to the part of the UI people use most.
        Localization.language = .japanese
        XCTAssertEqual(BlockShape.cylinder.displayName, "円柱")
        XCTAssertEqual(MaterialKind.neon.displayName, "ネオン")
        XCTAssertEqual(BlockBehavior.bounce.displayName, "トランポリン")
        XCTAssertEqual(BlockData.PresetKind.spawn.displayName, "スタート")

        Localization.language = .english
        XCTAssertEqual(BlockShape.cylinder.displayName, "Cylinder")
        XCTAssertEqual(BlockBehavior.bounce.displayName, "Bouncy")
    }

    func testEveryEnumDisplayNameIsTranslated() {
        // Walked from allCases, so a new shape, material, behaviour or part
        // fails here until it has a translation — the same ratchet the map
        // guide uses.
        Localization.language = .japanese
        defer { Localization.language = .english }

        func assertTranslated<T>(_ cases: [T], _ name: (T) -> String, _ what: String) {
            for value in cases {
                let translated = name(value)
                let hasJapanese = translated.unicodeScalars.contains {
                    (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                }
                XCTAssertTrue(hasJapanese, "\(what) \(value) still shows as \"\(translated)\"")
            }
        }

        assertTranslated(BlockShape.allCases, { $0.displayName }, "shape")
        assertTranslated(MaterialKind.allCases, { $0.displayName }, "material")
        assertTranslated(BlockBehavior.allCases, { $0.displayName }, "behaviour")
        assertTranslated(BlockBehavior.allCases, { $0.guidance }, "behaviour guidance")
        assertTranslated(BlockData.PresetKind.allCases, { $0.displayName }, "part")
        assertTranslated(BlockData.PresetKind.allCases, { $0.guidance }, "part guidance")
        assertTranslated(SoundCue.allCases, { $0.displayName }, "sound")
        assertTranslated(AvatarProfile.HatStyle.allCases, { $0.displayName }, "hat")
    }

    func testDisconnectMessagesAreTranslated() {
        // The one string a player is guaranteed to read at the worst moment.
        Localization.language = .japanese
        defer { Localization.language = .english }

        XCTAssertEqual(DisconnectReason.sessionFull.message, "そのワールドは満員です。")
        XCTAssertTrue(DisconnectReason.networkLost.message.contains("接続"))
    }

    func testRawValuesNeverChangeWithTheLanguage() {
        // `rawValue` is the wire format and the save format. If it followed the
        // UI language, a world saved on a Japanese iPad would not open on an
        // English one — and the two would fail to agree over the network.
        Localization.language = .japanese
        defer { Localization.language = .english }

        XCTAssertEqual(BlockBehavior.bounce.rawValue, "bounce")
        XCTAssertEqual(BlockShape.cylinder.rawValue, "cylinder")
        XCTAssertEqual(SoundCue.collect.rawValue, "collect")
        XCTAssertEqual(MaterialKind.neon.rawValue, "neon")
    }

    // MARK: Presentation

    func testEachLanguageNamesItselfInItsOwnLanguage() {
        // Someone who cannot read the current UI still has to find their row.
        XCTAssertEqual(Language.english.displayName, "English")
        XCTAssertEqual(Language.japanese.displayName, "日本語")

        Localization.language = .japanese
        XCTAssertEqual(LanguagePreference.japanese.displayName, "日本語")
        XCTAssertEqual(LanguagePreference.english.displayName, "English")
    }

    func testTheSystemOptionIsItselfTranslated() {
        Localization.language = .japanese
        XCTAssertEqual(LanguagePreference.system.displayName, "iPadに合わせる")
        Localization.language = .english
        XCTAssertEqual(LanguagePreference.system.displayName, "Match the iPad")
    }

    func testPreferencesAndLanguagesRoundTripThroughTheirRawValues() {
        // They are persisted by raw value, so renaming a case silently resets
        // everyone's choice.
        XCTAssertEqual(LanguagePreference(rawValue: "system"), .system)
        XCTAssertEqual(LanguagePreference(rawValue: "ja"), nil, "the preference is spelled 'japanese'")
        XCTAssertEqual(Language(rawValue: "ja"), .japanese)
        for preference in LanguagePreference.allCases {
            XCTAssertEqual(LanguagePreference(rawValue: preference.rawValue), preference)
        }
    }
}
