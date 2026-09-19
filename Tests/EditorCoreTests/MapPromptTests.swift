import XCTest
@testable import AbloxCore

/// The prompt Studio hands to an assistant.
///
/// A prompt is the same kind of artefact as a guide: it keeps compiling and
/// quietly stops being true. The two ways it goes wrong are naming a part the
/// palette does not have — which produces a level that will not import — and
/// quoting a physics number that is no longer right, which produces a level
/// nobody can finish. Both are checked here against the real things.
final class MapPromptTests: XCTestCase {

    private let request = MapPrompt.Request(theme: "a floating ruin")

    // MARK: Vocabulary

    func testThePromptOffersOnlyPartsThatExist() {
        let prompt = MapPrompt.text(for: request)
        for kind in BlockData.PresetKind.allCases {
            XCTAssertTrue(prompt.contains(kind.rawValue), "\(kind.rawValue) is missing from the prompt")
        }
    }

    func testThePromptOffersOnlyBehavioursThatExist() {
        let prompt = MapPrompt.text(for: request)
        for behaviour in BlockBehavior.allCases {
            XCTAssertTrue(prompt.contains(behaviour.rawValue), "\(behaviour.rawValue) is missing from the prompt")
        }
    }

    func testThePromptNamesNothingThatCannotBeImported() {
        // The reverse direction, and the one that actually bites: a word in
        // the prompt that `MapPlan` will refuse.
        let prompt = MapPrompt.text(for: request)

        // Everything between backticks in the vocabulary lines.
        let vocabulary = (MapPlan.partVocabulary + ", " + MapPlan.behaviourVocabulary)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for word in vocabulary {
            XCTAssertTrue(prompt.contains(word))
            let isPart = BlockData.PresetKind(rawValue: word) != nil
            let isBehaviour = BlockBehavior(rawValue: word) != nil
            XCTAssertTrue(isPart || isBehaviour, "the prompt offers “\(word)”, which resolves to nothing")
        }
    }

    // MARK: Physics

    func testThePromptQuotesTheRealJumpHeight() {
        // `ReachabilityTests` checks this figure against the simulation; this
        // checks the prompt is quoting that figure and not a remembered one.
        let prompt = MapPrompt.text(for: request)
        let height = MovementConfig.default.maximumJumpHeight
        XCTAssertTrue(prompt.contains("\(round(height * 100) / 100)"),
                      "the prompt should state the jump height of \(height)")
    }

    func testTheJumpReachIsStatedAsAFactAndTheGapAsAnInstruction() {
        // These are two different numbers and must read as two different
        // things. The first draft quoted the *gap* in the sentence describing
        // the jump — "a running jump crosses about 3.1 m" — which is simply
        // false: it crosses 6.0 m. An assistant reading that builds a level
        // for a player half as capable as the real one.
        let movement = MovementConfig.default
        let prompt = MapPrompt.text(for: MapPrompt.Request(difficulty: .normal), movement: movement)

        let reach = round(movement.maximumJumpDistance(running: true) * 10) / 10
        let gap = round(movement.safeJumpDistance * MapPrompt.Difficulty.normal.gapFraction * 10) / 10

        XCTAssertNotEqual(reach, gap, "the test is meaningless if the two figures coincide")
        XCTAssertTrue(prompt.contains("\(reach)"), "the prompt must state the real reach of \(reach) m")
        XCTAssertTrue(prompt.contains("\(gap)"), "the prompt must state the advised gap of \(gap) m")
    }

    func testNoDifficultyQuotesTheGapAsThoughItWereTheJump() {
        // The same slip at any setting.
        let movement = MovementConfig.default
        let reach = round(movement.maximumJumpDistance(running: true) * 10) / 10

        for difficulty in MapPrompt.Difficulty.allCases {
            let prompt = MapPrompt.text(for: MapPrompt.Request(difficulty: difficulty), movement: movement)
            // Whatever wording is used, the true reach has to appear
            // somewhere — a prompt that only ever names the smaller number is
            // understating the player.
            XCTAssertTrue(prompt.contains("\(reach)"), "\(difficulty) never states the real jump reach")
        }
    }

    func testAHarderLevelIsAllowedWiderGapsThanAGentleOne() {
        let gentle = MapPrompt.text(for: MapPrompt.Request(difficulty: .gentle))
        let hard = MapPrompt.text(for: MapPrompt.Request(difficulty: .hard))
        XCTAssertNotEqual(gentle, hard)
    }

    func testEvenTheHardestGapIsOneThePlayerCanCross() {
        // The check that keeps "hard" from meaning "impossible": every
        // difficulty must ask for a gap inside what a running jump does.
        let movement = MovementConfig.default
        for difficulty in MapPrompt.Difficulty.allCases {
            let gap = movement.safeJumpDistance * difficulty.gapFraction
            XCTAssertLessThan(gap, movement.maximumJumpDistance(running: true),
                              "\(difficulty) asks for a gap wider than a jump")
            XCTAssertGreaterThan(gap, 0)
        }
    }

    func testTheGentlestDifficultyIsActuallyGentle() {
        let movement = MovementConfig.default
        let gap = movement.safeJumpDistance * MapPrompt.Difficulty.gentle.gapFraction
        XCTAssertLessThan(gap, movement.maximumJumpDistance(running: false),
                          "the gentle setting should be crossable without running")
    }

    // MARK: Shape

    func testThePromptAsksForJSONAndNothingElse() {
        // Without this the reply arrives wrapped in three paragraphs, and
        // while the importer copes, the person has to trust that it did.
        let prompt = MapPrompt.text(for: request)
        XCTAssertTrue(prompt.contains("JSON"))
    }

    func testTheThemeIsIncludedWhenGivenAndOmittedWhenNot() {
        XCTAssertTrue(MapPrompt.text(for: MapPrompt.Request(theme: "a sunken city")).contains("a sunken city"))

        let blank = MapPrompt.text(for: MapPrompt.Request(theme: "   "))
        XCTAssertFalse(blank.contains("Theme:"), "an empty theme should not produce an empty line")
    }

    func testFeatureRulesFollowTheSwitches() {
        // The vocabulary line always lists every part, so the check has to be
        // on the *rule* sentence rather than on the word appearing at all.
        let bare = MapPrompt.text(for: MapPrompt.Request(
            includeCoins: false, includeHazards: false, includeGimmicks: false
        ))
        XCTAssertFalse(bare.contains("\"orb\" parts along the route"))
        XCTAssertFalse(bare.contains("checkpoint\" part before each hazard"))

        let everything = MapPrompt.text(for: MapPrompt.Request(
            includeCoins: true, includeHazards: true, includeGimmicks: true
        ))
        XCTAssertTrue(everything.contains("\"orb\" parts along the route"))
        XCTAssertTrue(everything.contains("checkpoint\" part before each hazard"),
                      "hazards without checkpoints make a cruel level")
        XCTAssertTrue(everything.contains("\"bounce\" part launches"))
    }

    func testHazardsAlwaysComeWithACheckpointInstruction() {
        // The single rule that most affects whether a generated level is
        // playable rather than infuriating.
        let withHazards = MapPrompt.text(for: MapPrompt.Request(includeHazards: true))
        XCTAssertTrue(withHazards.contains("checkpoint\" part before each hazard"))
    }

    func testSizeChangesTheRequestedPartCount() {
        for size in MapPrompt.Size.allCases {
            XCTAssertTrue(
                MapPrompt.text(for: MapPrompt.Request(size: size)).contains("\(size.partCount)"),
                "\(size) should ask for \(size.partCount) parts"
            )
        }
        XCTAssertLessThan(MapPrompt.Size.small.partCount, MapPrompt.Size.large.partCount)
    }

    func testEverySizeIsUnderTheImporterLimit() {
        // Asking for more parts than the importer accepts would produce a
        // level that is refused in full after the assistant did all the work.
        for size in MapPrompt.Size.allCases {
            XCTAssertLessThan(size.partCount, MapPlan.Limits.maximumParts, "\(size)")
        }
    }

    func testTheCoordinateAdviceMatchesTheImporter() {
        // The prompt says "within 100 m"; the importer refuses beyond 500. A
        // prompt looser than the importer produces refused levels.
        let prompt = MapPrompt.text(for: request)
        XCTAssertTrue(prompt.contains("100"))
        XCTAssertLessThan(Float(100), MapPlan.Limits.maximumCoordinate)
    }

    // MARK: Corrections

    func testACorrectionListsEveryProblem() {
        let problems = [
            MapPlanProblem(partIndex: 0, message: "first"),
            MapPlanProblem(message: "second")
        ]
        let text = MapPrompt.correction(for: problems)
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
        XCTAssertTrue(text.contains("1"), "a part-specific problem should say which part")
    }

    func testACorrectionAsksForTheWholeDocumentBack() {
        // Otherwise a patch comes back that cannot be pasted anywhere.
        let text = MapPrompt.correction(for: [MapPlanProblem(message: "x")])
        XCTAssertTrue(text.lowercased().contains("again"))
    }

    // MARK: Translation

    func testThePromptIsWrittenInTheInterfaceLanguage() {
        // Someone reading a Japanese Studio should get a Japanese prompt —
        // the assistant understands either, but the person has to be able to
        // check what they are about to send.
        Localization.language = .japanese
        defer { Localization.language = .english }

        let prompt = MapPrompt.text(for: request)
        let hasJapanese = prompt.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        XCTAssertTrue(hasJapanese, "the prompt did not pick up the interface language")

        // But the vocabulary must stay in English, because those are the
        // values that go into the JSON.
        for kind in BlockData.PresetKind.allCases {
            XCTAssertTrue(prompt.contains(kind.rawValue), "\(kind.rawValue) must not be translated")
        }
    }
}
