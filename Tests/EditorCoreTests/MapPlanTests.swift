import XCTest
@testable import AbloxCore

/// Importing a level an assistant wrote.
///
/// The input here is not hostile, it is *unreliable* — and unreliable in
/// specific, repeatable ways: a code fence around the JSON, a sentence before
/// it, numbers in quotes, an invented part name, coordinates in the thousands.
/// Each of those has its own test, because each produces a different thing to
/// say back to whoever wrote it.
final class MapPlanTests: XCTestCase {

    // MARK: Finding the JSON

    func testPlainJSONIsRead() {
        let text = #"{"name":"A","parts":[{"kind":"block","x":0,"y":0,"z":0}]}"#
        guard case let .success(plan) = MapPlan.decode(from: text) else {
            return XCTFail("should have parsed")
        }
        XCTAssertEqual(plan.name, "A")
        XCTAssertEqual(plan.parts.count, 1)
    }

    func testACodeFenceIsStripped() {
        // Every assistant adds one, and asking a child to delete it on an iPad
        // keyboard is not a reasonable thing to require.
        let text = """
        Here is your level!

        ```json
        {"name":"Fenced","parts":[{"kind":"block","x":1,"y":2,"z":3}]}
        ```

        Let me know if you want it harder.
        """
        guard case let .success(plan) = MapPlan.decode(from: text) else {
            return XCTFail("should have parsed")
        }
        XCTAssertEqual(plan.name, "Fenced")
        XCTAssertEqual(plan.parts.first?.y, 2)
    }

    func testNestedObjectsDoNotTruncateTheDocument() {
        // Brace matching rather than "up to the first }", which would cut this
        // off mid-document and fail for a reason nobody could act on.
        let text = #"{"name":"N","summary":"a {nested} word","parts":[{"kind":"block","x":0,"y":0,"z":0}]}"#
        guard case let .success(plan) = MapPlan.decode(from: text) else {
            return XCTFail("should have parsed")
        }
        XCTAssertEqual(plan.summary, "a {nested} word")
    }

    func testBracesInsideStringsAreIgnored() {
        let extracted = MapPlan.extractJSON(from: #"prose {"a":"}{"} more"#)
        XCTAssertEqual(extracted, #"{"a":"}{"}"#)
    }

    func testTextWithNoJSONSaysSo() {
        guard case let .failure(problem) = MapPlan.decode(from: "I cannot help with that.") else {
            return XCTFail("should have failed")
        }
        XCTAssertFalse(problem.message.isEmpty)
    }

    func testAnEnormousPasteIsRefusedBeforeParsing() {
        let huge = String(repeating: "{", count: MapPlan.Limits.maximumTextBytes + 1)
        guard case .failure = MapPlan.decode(from: huge) else {
            return XCTFail("should have been refused")
        }
    }

    func testNumbersInQuotesGetAUsefulMessage() {
        // The single most common mistake, and "the data couldn’t be read"
        // would be a useless thing to hand back.
        let text = #"{"name":"A","parts":[{"kind":"block","x":"0","y":0,"z":0}]}"#
        guard case let .failure(problem) = MapPlan.decode(from: text) else {
            return XCTFail("should have failed")
        }
        XCTAssertTrue(problem.message.contains("x"), problem.message)
    }

    // MARK: Building a world

    private func plan(_ parts: [MapPlan.Part], name: String = "Test") -> MapPlan {
        MapPlan(name: name, parts: parts)
    }

    func testAMinimalPlanBecomesAWorld() {
        let result = plan([
            MapPlan.Part(kind: "spawn", x: 0, y: 0.1, z: 5),
            MapPlan.Part(kind: "platform", x: 0, y: 0.25, z: 0),
            MapPlan.Part(kind: "goal", x: 0, y: 1.5, z: -5)
        ]).build()

        XCTAssertTrue(result.isUsable)
        XCTAssertEqual(result.world?.blocks.count, 3)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(result.world?.name, "Test")
    }

    func testSizesAreApplledPerAxis() {
        // Giving only a height must not reset width and depth to 1.
        let result = plan([
            MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "platform", x: 0, y: 0, z: 0, height: 2)
        ]).build()

        let platform = try? XCTUnwrap(result.world?.blocks.last)
        XCTAssertEqual(platform?.scale.y, 2)
        XCTAssertEqual(platform?.scale.x, BlockData.preset(.platform, at: .zero).scale.x,
                       "width was not asked for and must keep the preset's")
    }

    func testAnInventedPartNameIsNamedInTheError() {
        // So it can be pasted straight back: "castle is not a part, use…".
        let result = plan([MapPlan.Part(kind: "castle", x: 0, y: 0, z: 0)]).build()
        XCTAssertFalse(result.isUsable)
        let message = result.problems.first?.message ?? ""
        XCTAssertTrue(message.contains("castle"), message)
        XCTAssertTrue(message.contains("platform"), "the message should list what is allowed")
    }

    func testAnInventedBehaviourIsNamedInTheError() {
        let result = plan([
            MapPlan.Part(kind: "block", x: 0, y: 0, z: 0, behavior: "explodes")
        ]).build()
        let message = result.problems.first?.message ?? ""
        XCTAssertTrue(message.contains("explodes"), message)
    }

    func testEveryProblemIsReportedAtOnce() {
        // Not the first. Someone pasting this back should be able to fix it in
        // one round rather than five.
        let result = plan([
            MapPlan.Part(kind: "nonsense", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "block", x: 0, y: 0, z: 0, color: "not-a-colour"),
            MapPlan.Part(kind: "block", x: 9_000, y: 0, z: 0)
        ]).build()

        XCTAssertGreaterThanOrEqual(result.problems.count, 3)
    }

    func testProblemsSayWhichPart() {
        let result = plan([
            MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "nonsense", x: 0, y: 0, z: 0)
        ]).build()

        XCTAssertEqual(result.problems.first?.partIndex, 1)
        // One-based in the text, because the JSON a person is reading is not
        // zero-indexed to their eye.
        XCTAssertTrue(result.problems.first?.description.contains("2") ?? false)
    }

    func testOneBadPartDoesNotThrowAwayTheOthers() {
        let result = plan([
            MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "nonsense", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "goal", x: 0, y: 0, z: -5)
        ]).build()

        XCTAssertTrue(result.isUsable)
        XCTAssertEqual(result.world?.blocks.count, 2)
        XCTAssertEqual(result.problems.count, 1)
    }

    func testAMissingSpawnIsAddedAndSaidOutLoud() {
        // A world with no spawn opens and cannot be played. Adding one is
        // friendlier than refusing the import over something forgotten — but
        // silently changing what someone asked for is not.
        let result = plan([MapPlan.Part(kind: "goal", x: 0, y: 0, z: -5)]).build()

        XCTAssertTrue(result.isUsable)
        XCTAssertTrue(result.world?.blocks.contains { $0.behavior == .spawn } ?? false)
        XCTAssertEqual(result.problems.count, 1)
    }

    func testAPlanWithNoUsablePartsProducesNoWorld() {
        let result = plan([MapPlan.Part(kind: "nonsense", x: 0, y: 0, z: 0)]).build()
        XCTAssertFalse(result.isUsable)
        XCTAssertNil(result.world)
    }

    func testAnEmptyPlanIsRefused() {
        XCTAssertFalse(plan([]).build().isUsable)
    }

    // MARK: Limits

    func testTooManyPartsAreRefusedRatherThanBuilt() {
        // Building six hundred thousand blocks to then say "too many" is the
        // problem this avoids.
        let many = (0..<(MapPlan.Limits.maximumParts + 1)).map { index in
            MapPlan.Part(kind: "block", x: Float(index % 30), y: 0, z: 0)
        }
        let result = plan(many).build()
        XCTAssertFalse(result.isUsable)
        XCTAssertEqual(result.problems.count, 1)
    }

    func testCoordinatesOffTheMapAreRefused() {
        for value in [Float(9_000), -9_000, .infinity, .nan] {
            let result = plan([MapPlan.Part(kind: "block", x: value, y: 0, z: 0)]).build()
            XCTAssertFalse(result.isUsable, "\(value) should not be placeable")
        }
    }

    func testDegenerateSizesAreRefused() {
        // A zero-scaled part is invisible and still blocks the player — the
        // exact thing the world validator warns about, so it should never be
        // imported in the first place.
        for size in [Float(0), -1, 9_999, .nan] {
            let result = plan([
                MapPlan.Part(kind: "block", x: 0, y: 0, z: 0, width: size)
            ]).build()
            XCTAssertFalse(result.isUsable, "width \(size) should be refused")
        }
    }

    func testAnOverlongNameIsTrimmedRatherThanRefused() {
        let long = String(repeating: "a", count: 500)
        let result = MapPlan(name: long, parts: [MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0)]).build()
        XCTAssertTrue(result.isUsable)
        XCTAssertEqual(result.world?.name.count, MapPlan.Limits.maximumNameLength)
    }

    func testAnEmptyNameFallsBackRatherThanProducingAnUnnamedWorld() {
        let result = MapPlan(name: "   ", parts: [MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0)])
            .build(named: "Fallback")
        XCTAssertEqual(result.world?.name, "Fallback")
    }

    // MARK: Colours and rotation

    func testAHexColourIsApplied() {
        let result = plan([
            MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "block", x: 0, y: 0, z: 0, color: "#FF0000")
        ]).build()

        let colour = result.world?.blocks.last?.color
        XCTAssertEqual(colour?.r ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(colour?.g ?? 1, 0, accuracy: 0.01)
    }

    func testYawBecomesARotation() {
        let result = plan([
            MapPlan.Part(kind: "spawn", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "block", x: 0, y: 0, z: 0, yaw: 90)
        ]).build()

        XCTAssertNotEqual(result.world?.blocks.last?.transform.rotation, Quat.identity)
    }

    // MARK: Vocabulary

    func testTheVocabularyIsTheRealOne() {
        // Read from allCases, so adding a part to the palette updates what the
        // prompt offers with no separate edit — and the prompt can never name
        // something that does not exist.
        for kind in BlockData.PresetKind.allCases {
            XCTAssertTrue(MapPlan.partVocabulary.contains(kind.rawValue), kind.rawValue)
        }
        for behaviour in BlockBehavior.allCases {
            XCTAssertTrue(MapPlan.behaviourVocabulary.contains(behaviour.rawValue), behaviour.rawValue)
        }
    }

    func testEveryVocabularyWordActuallyImports() {
        // The round trip that matters: everything the prompt offers has to
        // survive being written down and read back.
        for kind in BlockData.PresetKind.allCases {
            let result = plan([MapPlan.Part(kind: kind.rawValue, x: 0, y: 0, z: 0)]).build()
            XCTAssertTrue(result.isUsable, "\(kind.rawValue) is offered but does not import")
        }
        for behaviour in BlockBehavior.allCases {
            let result = plan([
                MapPlan.Part(kind: "block", x: 0, y: 0, z: 0, behavior: behaviour.rawValue)
            ]).build()
            XCTAssertTrue(result.isUsable, "\(behaviour.rawValue) is offered but does not import")
        }
    }

    func testKindAndBehaviourAreCaseInsensitive() {
        // Assistants capitalise. It is not worth a failed import.
        let result = plan([
            MapPlan.Part(kind: "Spawn", x: 0, y: 0, z: 0),
            MapPlan.Part(kind: "BLOCK", x: 0, y: 0, z: 0, behavior: "Bounce")
        ]).build()
        XCTAssertTrue(result.isUsable)
        XCTAssertEqual(result.world?.blocks.last?.behavior, .bounce)
    }

    // MARK: The example in the prompt

    func testTheWorkedExampleInThePromptImports() {
        // The example is the one thing an assistant copies most closely. If it
        // were wrong, every generated level would be wrong the same way.
        guard case let .success(plan) = MapPlan.decode(from: MapPrompt.example) else {
            return XCTFail("the prompt's own example does not parse")
        }
        let result = plan.build()
        XCTAssertTrue(result.isUsable)
        XCTAssertTrue(result.problems.isEmpty, "\(result.problems.map(\.description))")
        XCTAssertTrue(result.world?.blocks.contains { $0.behavior == .spawn } ?? false)
        XCTAssertTrue(result.world?.blocks.contains { $0.behavior == .goal } ?? false)
    }
}
