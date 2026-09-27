import XCTest
@testable import AbloxCore

/// Studio's building tools and script helpers, without an iPad.
final class EditingToolsTests: XCTestCase {

    private func document(parts: Int) -> (EditorDocument, [UUID]) {
        var doc = EditorDocument(world: .blank(named: "Tools"))
        doc.gridSize = 0
        var ids: [UUID] = []
        for index in 0..<parts {
            ids.append(doc.addPart(.block, at: Vec3(Float(index) * 5, 0, Float(index))))
        }
        doc.selection = Set(ids)
        return (doc, ids)
    }

    // MARK: Picking

    func testLockedAndHiddenLayerPartsAreNotPicked() {
        var (doc, ids) = document(parts: 3)
        doc.selection = [ids[0]]
        doc.setLocked(true)
        doc.selection = [ids[1]]
        doc.setLayer("Trees")
        doc.hiddenLayers = ["Trees"]
        doc.selectBlocks(ids, additive: false)
        XCTAssertEqual(doc.selection, [ids[2]])
    }

    // MARK: Copy and paste

    func testCopiedPartsPasteIntoAnotherWorld() throws {
        var (doc, _) = document(parts: 2)
        let clip = try XCTUnwrap(doc.copySelection())
        let data = try XCTUnwrap(clip.encoded)
        let received = try XCTUnwrap(PartClipboard(data: data))

        var other = EditorDocument(world: .blank(named: "Other"))
        let before = other.world.blocks.count
        let pasted = other.paste(received, at: Vec3(10, 0, 10))
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(other.world.blocks.count, before + 2)
        XCTAssertTrue(pasted.allSatisfy { id in !doc.world.blocks.contains { $0.id == id } }, "new ids")
        XCTAssertTrue(other.undo())
        XCTAssertEqual(other.world.blocks.count, before, "one undo step")
        _ = doc
    }

    // MARK: Lining up and repeating

    func testAlignAndDistribute() {
        var (doc, ids) = document(parts: 3)
        doc.align(.z, to: .minimum)
        let zs = ids.compactMap { doc.world.worldBounds(of: $0)?.min.z }
        XCTAssertEqual(Set(zs.map { ($0 * 100).rounded() }).count, 1)

        let block = doc.world.block(id: ids[1])!
        var moved = block
        moved.position.x = 1
        doc.perform(.modify(before: block, after: moved))
        doc.selection = Set(ids)
        doc.distribute(.x)
        let xs = ids.compactMap { doc.world.worldBounds(of: $0)?.center.x }.sorted()
        XCTAssertEqual(xs[1] - xs[0], xs[2] - xs[1], accuracy: 0.01)
    }

    func testRepeatsAreOneUndoStep() {
        var (doc, _) = document(parts: 1)
        let before = doc.world.blocks.count
        doc.repeatInRow(count: 9, offset: Vec3(3, 0, 0))
        XCTAssertEqual(doc.world.blocks.count, before + 9)
        XCTAssertEqual(doc.selection.count, 10)
        doc.undo()
        XCTAssertEqual(doc.world.blocks.count, before)

        doc.repeatInRing(count: 6, radius: 5)
        XCTAssertEqual(doc.world.blocks.count, before + 5)
    }

    func testMirrorFlipsAcrossTheMiddle() {
        var (doc, ids) = document(parts: 2)
        let a = doc.world.block(id: ids[0])!.position.x
        let b = doc.world.block(id: ids[1])!.position.x
        doc.mirror(.x, copy: false)
        XCTAssertEqual(doc.world.block(id: ids[0])!.position.x, b, accuracy: 0.01)
        XCTAssertEqual(doc.world.block(id: ids[1])!.position.x, a, accuracy: 0.01)
        let count = doc.world.blocks.count
        doc.mirror(.x, copy: true)
        XCTAssertEqual(doc.world.blocks.count, count + 2)
    }

    // MARK: Painting and the ground

    func testPaintKeepsSeeThrough() {
        var (doc, ids) = document(parts: 1)
        let block = doc.world.block(id: ids[0])!
        var glass = block
        glass.color = glass.color.withAlpha(0.4)
        doc.perform(.modify(before: block, after: glass))
        doc.paint(ids[0], with: ColorRGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(doc.world.block(id: ids[0])!.color, ColorRGBA(r: 1, g: 0, b: 0, a: 0.4))
    }

    func testTheGroundGoesUpAndDown() {
        var doc = EditorDocument(world: .blank(named: "Hills"))
        doc.shapeTerrain(.raise, at: Vec3(0.4, 0, 0.3))
        doc.shapeTerrain(.raise, at: Vec3(0, 0, 0))
        let column = try? XCTUnwrap(doc.terrainColumn(at: .zero))
        XCTAssertEqual(column?.scale.y, 2)
        XCTAssertEqual(column?.position.y, 1, "its base stays on the ground")
        doc.shapeTerrain(.lower, at: .zero)
        doc.shapeTerrain(.lower, at: .zero)
        XCTAssertNil(doc.terrainColumn(at: .zero), "dug away")

        doc.generateTerrain(size: 6, height: 4, seed: 3)
        XCTAssertEqual(doc.world.blocks.filter { $0.hasTag(EditorDocument.terrainTag) }.count, 36)
        let first = doc.world.blocks.filter { $0.hasTag(EditorDocument.terrainTag) }.map(\.scale.y)
        var again = EditorDocument(world: .blank(named: "Hills"))
        again.generateTerrain(size: 6, height: 4, seed: 3)
        XCTAssertEqual(again.world.blocks.filter { $0.hasTag(EditorDocument.terrainTag) }.map(\.scale.y), first, "same seed, same hills")
    }

    func testWeightNamesWhatIsHeavy() {
        var world = WorldDocument.blank(named: "Heavy")
        XCTAssertEqual(WorldWeight.assess(world).level, .light)
        for index in 0..<3_200 { world.blocks.append(BlockData(name: "B\(index)")) }
        let weight = WorldWeight.assess(world)
        XCTAssertGreaterThanOrEqual(weight.level, .heavy)
        XCTAssertFalse(weight.advice.isEmpty)
    }

    func testHistoryCanBeWalkedBack() {
        var (doc, _) = document(parts: 3)
        XCTAssertEqual(doc.historySteps.count, 3)
        doc.undo(toStep: 1)
        XCTAssertEqual(doc.historySteps.count, 1)
        XCTAssertEqual(doc.world.blocks.count, WorldDocument.blank(named: "x").blocks.count + 1)
    }

    // MARK: Map AI for one area

    func testRemakingAnAreaReplacesOnlyTheSelection() throws {
        var (doc, ids) = document(parts: 3)
        doc.selection = [ids[0], ids[1]]
        let area = try XCTUnwrap(doc.selectedArea)
        XCTAssertGreaterThanOrEqual(area.width, MapArea.minimumSide)
        XCTAssertTrue(area.contains(doc.world.block(id: ids[0])!.position))

        let prompt = MapPrompt.text(for: MapPrompt.Request(theme: "pond"), area: area, around: doc.parts(around: area, margin: 20))
        XCTAssertTrue(prompt.contains(doc.world.block(id: ids[2])!.name), "the part that stays is described")

        let inside = String(format: "%.1f", Double(area.minX + 0.5))
        let json = """
        {"name": "Pond", "parts": [
          {"kind": "block", "x": \(inside), "y": 0.5, "z": \(String(format: "%.1f", Double(area.minZ + 0.5)))},
          {"kind": "block", "x": \(inside), "y": 1.5, "z": \(String(format: "%.1f", Double(area.minZ + 0.5)))},
          {"kind": "block", "x": 400, "y": 0.5, "z": 400}
        ]}
        """
        let plan = try MapPlan.decode(from: json).get()
        let before = doc.world.blocks.count
        let result = doc.remakeSelection(with: plan, in: area)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.leftOut, 1, "the far part is left out")
        XCTAssertTrue(result.problems.isEmpty, "no spawn is added: \(result.problems)")
        XCTAssertEqual(doc.world.blocks.count, before)
        XCTAssertNotNil(doc.world.block(id: ids[2]), "the rest of the world stays")
        XCTAssertNil(doc.world.block(id: ids[0]))
        XCTAssertFalse(doc.world.blocks.contains { $0.behavior == .spawn && $0.name == L("Spawn") && doc.selection.contains($0.id) })
        XCTAssertTrue(doc.undo())
        XCTAssertNotNil(doc.world.block(id: ids[0]), "one undo brings it back")
    }

    // MARK: Scripts

    func testSuggestionsFollowWhatIsTyped() {
        let source = "let coins = 0\non join(p)\n  p.hea"
        let context = ScriptCompletion.context(in: source, cursor: (source as NSString).length)
        XCTAssertEqual(context.receiver, "p")
        XCTAssertEqual(context.prefix, "hea")
        let names = ScriptCompletion.suggestions(for: context, source: source, blockNames: []).map(\.text)
        XCTAssertTrue(names.contains("health"), "\(names)")

        let partSource = "block(\"Do"
        let partContext = ScriptCompletion.context(in: partSource, cursor: (partSource as NSString).length)
        XCTAssertTrue(partContext.inBlockName)
        XCTAssertEqual(ScriptCompletion.suggestions(for: partContext, source: partSource, blockNames: ["Door", "Floor"]).map(\.text), ["Door"])

        let mine = "let coins = 0\nco"
        let own = ScriptCompletion.suggestions(for: ScriptCompletion.context(in: mine, cursor: (mine as NSString).length),
                                               source: mine, blockNames: []).map(\.text)
        XCTAssertTrue(own.contains("coins"))

        let event = "on jo"
        XCTAssertEqual(ScriptCompletion.suggestions(for: ScriptCompletion.context(in: event, cursor: 5), source: event,
                                                    blockNames: []).first?.text, "join")
    }

    func testOutlineAndFormatting() {
        let messy = """
        let x = 1
        on join(p)
        if p.score > 1 then
        p.message("hi")
        elif p.score < 0 then
        p.message("-- not a comment")
        else
        every(1, func()
        print(x)
        end)
        end
        end
        func add(a, b) return a + b end
        """
        let tidy = ScriptFormatter.format(messy)
        XCTAssertEqual(tidy, """
        let x = 1
        on join(p)
          if p.score > 1 then
            p.message("hi")
          elif p.score < 0 then
            p.message("-- not a comment")
          else
            every(1, func()
              print(x)
            end)
          end
        end
        func add(a, b) return a + b end
        """)
        XCTAssertEqual(ScriptFormatter.format(tidy), tidy, "running it twice changes nothing")
        let outline = ScriptOutline.items(in: tidy)
        XCTAssertEqual(outline.map(\.kind), [.variable, .event, .function])
        XCTAssertEqual(outline[1].line, 2)
    }

    func testSearchAndReplaceEveryFile() {
        let files = [ScriptFile(name: "a", source: "let coins = 0\ncoins = coins + 1"), ScriptFile(name: "b", source: "print(Coins)")]
        XCTAssertEqual(ScriptSearch.find("coins", in: files).count, 4)
        XCTAssertEqual(ScriptSearch.find("coins", in: files, caseSensitive: true).count, 3)
        let replaced = ScriptSearch.replaceAll("coins", with: "gold", in: files)
        XCTAssertEqual(replaced.count, 4)
        XCTAssertEqual(replaced.files[1].source, "print(gold)")
    }

    func testDiffShowsWhatChanged() {
        let diff = TextDiff.lines(from: "a\nb\nc\nd", to: "a\nc\nx\nd")
        XCTAssertEqual(diff.map(\.kind), [.same, .removed, .same, .added, .same])
        XCTAssertEqual(diff.filter { $0.kind == .added }.map(\.text), ["x"])
    }

    func testSnippetsAreValidCode() {
        for snippet in ScriptSnippets.all {
            XCTAssertTrue(GameRuntime.check([ScriptFile(name: "s", source: snippet.code)]).isEmpty,
                          "\(snippet.title): \(GameRuntime.check([ScriptFile(name: "s", source: snippet.code)]))")
        }
    }

    func testBlockProgramsMakeWorkingCode() {
        var program = BlockProgram()
        program.cards = [
            BlockProgram.Card(trigger: .start, steps: [BlockProgram.Step(action: .announce, text: "Go!"),
                                                      BlockProgram.Step(action: .giveWeapon, text: "blaster")]),
            BlockProgram.Card(trigger: .join, steps: [BlockProgram.Step(action: .message, text: "Say \"hi\""),
                                                     BlockProgram.Step(action: .showButton, text: "jump")]),
            BlockProgram.Card(trigger: .touch, value: "Pad", steps: [BlockProgram.Step(action: .addScore, number: 5),
                                                                     BlockProgram.Step(action: .launch, number: 20)]),
            BlockProgram.Card(trigger: .touch, value: "Lava", steps: [BlockProgram.Step(action: .teleport, part: "Start")]),
            BlockProgram.Card(trigger: .button, value: "jump", steps: [BlockProgram.Step(action: .jump, number: 2)]),
            BlockProgram.Card(trigger: .every, value: "2", steps: [BlockProgram.Step(action: .addScore, number: 1),
                                                                   BlockProgram.Step(action: .colorPart, text: "red", part: "Pad")]),
            BlockProgram.Card(trigger: .chat, value: "Hello", steps: [BlockProgram.Step(action: .particles, text: "hearts")])
        ]
        let file = ScriptFile(name: "blocks", source: program.fileSource)
        XCTAssertTrue(GameRuntime.check([file]).isEmpty, "\(GameRuntime.check([file]))\n\(program.source)")
        XCTAssertEqual(BlockProgram(file: file), program, "the cards come back out of the file")
        XCTAssertNil(BlockProgram(file: ScriptFile(name: "code", source: "print(1)")))

        var world = WorldDocument.blank(named: "Blocks")
        world.blocks += [BlockData(name: "Pad", behavior: .trigger), BlockData(name: "Start"), BlockData(name: "Lava", behavior: .trigger)]
        world.scripts = [file]
        let report = GameRuntime.testRun(world: world, seconds: 3, robots: true)
        XCTAssertTrue(report.isClean, "\(report.problems)")
    }
}
