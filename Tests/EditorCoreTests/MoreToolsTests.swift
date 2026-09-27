import XCTest
@testable import AbloxCore

/// World check, statistics, the newer building tools and the line tools of
/// the script editor, without an iPad.
final class MoreToolsTests: XCTestCase {

    private func document() -> EditorDocument {
        var doc = EditorDocument(world: .blank(named: "Tools"))
        doc.gridSize = 0
        return doc
    }

    // MARK: World check

    func testABlankWorldIsClean() {
        XCTAssertTrue(WorldCheck.run(WorldDocument.blank()).isClean)
    }

    func testMissingAndSunkenSpawns() throws {
        var world = WorldDocument.blank()
        world.blocks.removeAll { $0.behavior == .spawn }
        XCTAssertEqual(WorldCheck.run(world).findings.map(\.id), ["no-spawn"])

        world.blocks.append(BlockData.preset(.spawn, at: Vec3(0, -80, 0)))
        let check = WorldCheck.run(world)
        let sunk = try XCTUnwrap(check.findings.first { $0.id == "spawn-below" })
        XCTAssertEqual(sunk.level, .problem)
        XCTAssertEqual(sunk.blocks.count, 1)
        XCTAssertEqual(check.worst, .problem)
        XCTAssertEqual(check.findings.first?.id, "spawn-below", "worst first")
    }

    func testStackedPartsAndCleanUp() {
        var doc = document()
        let id = doc.addPart(.block, at: Vec3(3, 1, 3))
        doc.selection = [id]
        doc.duplicateSelection()
        // A copy moved back onto the original: identical.
        let copy = doc.selection.first!
        doc.selection = [copy]
        doc.translateSelection(by: Vec3(-1, 0, 0))
        XCTAssertEqual(WorldCheck.duplicates(in: doc.world), [copy])
        XCTAssertTrue(WorldCheck.run(doc.world).findings.contains { $0.id == "doubles" })

        let before = doc.world.blocks.count
        XCTAssertEqual(doc.removeDuplicates(), 1)
        XCTAssertEqual(doc.world.blocks.count, before - 1)
        XCTAssertNotNil(doc.world.block(id: id), "the first stays")
        doc.undo()
        XCTAssertEqual(doc.world.blocks.count, before, "one undo step")
    }

    func testScriptsAskingForPartsByName() {
        var world = WorldDocument.blank()
        var door = BlockData.preset(.block, at: Vec3(0, 1, 0))
        door.name = "Door"
        world.blocks.append(door)
        var twin = door
        twin.id = UUID()
        twin.name = "Gate"
        world.blocks.append(twin)
        var another = twin
        another.id = UUID()
        world.blocks.append(another)
        world.scripts = [ScriptFile(name: "main", source: """
        local d = block("door")          -- any case finds it
        local g = block( ’Gate’ )
        local x = block("Missing")
        -- block("Commented")
        local made = create_block("Nope")
        """)]
        XCTAssertEqual(WorldCheck.referencedNames(in: world.scripts), ["door", "Gate", "Missing"])
        let ids = Set(WorldCheck.run(world).findings.map(\.id))
        XCTAssertTrue(ids.contains("missing-Missing"))
        XCTAssertTrue(ids.contains("twice-Gate"))
        XCTAssertFalse(ids.contains("missing-door"))
    }

    func testStatistics() {
        var world = WorldDocument.blank()
        world.scripts = [ScriptFile(name: "a", source: "print(1)\nprint(2)")]
        let stats = WorldStatistics.of(world)
        XCTAssertEqual(stats.parts, 2)
        XCTAssertEqual(stats.scriptFiles, 1)
        XCTAssertEqual(stats.scriptLines, 2)
        XCTAssertEqual(stats.shapes.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(stats.behaviours.map(\.count), [1], "the spawn; plain parts are not listed")
        XCTAssertEqual(stats.size.x, 40, accuracy: 0.01)
        XCTAssertLessThanOrEqual(stats.colours.count, 8)
    }

    // MARK: Colours

    func testReplaceColourEverywhereOrInTheSelection() {
        var doc = document()
        let red = ColorRGBA(hex: "#EF4444")!, blue = ColorRGBA(hex: "#3B82F6")!
        let a = doc.addPart(.block, at: Vec3(5, 1, 0))
        let b = doc.addPart(.block, at: Vec3(9, 1, 0))
        doc.selection = [a, b]
        doc.mutateSelection(label: "Paint") { $0.color = red.withAlpha(0.5) }
        doc.selection = []
        XCTAssertTrue(doc.coloursInUse.contains { EditorDocument.sameColour($0, red) })
        XCTAssertEqual(doc.replaceColour(red, with: blue), 2)
        XCTAssertEqual(doc.world.block(id: a)?.color, blue.withAlpha(0.5), "see-through stays")
        doc.undo()
        doc.selection = [a]
        XCTAssertEqual(doc.replaceColour(red, with: blue), 1)
        XCTAssertTrue(EditorDocument.sameColour(doc.world.block(id: b)!.color, red))
    }

    func testVaryColoursIsRepeatableAndStaysInRange() {
        func varied() -> [ColorRGBA] {
            var doc = document()
            let ids = (0..<5).map { doc.addPart(.block, at: Vec3(Float($0) * 3, 1, 0)) }
            doc.selection = Set(ids)
            doc.varyColours(amount: 0.3, seed: 99)
            return ids.compactMap { doc.world.block(id: $0)?.color }
        }
        let a = varied(), b = varied()
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(Set(a.map(\.hexString)).count, 1)
        XCTAssertTrue(a.allSatisfy { [$0.r, $0.g, $0.b].allSatisfy { (0...1).contains($0) } })
    }

    // MARK: Scatter and drop

    func testScatterStaysInsideTheCircle() {
        var doc = document()
        let tree = doc.addPart(.pillar, at: Vec3(0, 2, 0))
        doc.selection = [tree]
        let before = doc.world.blocks.count
        doc.scatter(count: 30, radius: 10, seed: 7)
        XCTAssertEqual(doc.world.blocks.count, before + 30)
        XCTAssertEqual(doc.selection.count, 30)
        for id in doc.selection {
            let p = doc.world.worldPosition(of: id)
            XCTAssertLessThanOrEqual((p.x * p.x + p.z * p.z).squareRoot(), 10.01)
        }
        doc.undo()
        XCTAssertEqual(doc.world.blocks.count, before, "one undo step")
    }

    func testDropToGroundLandsOnWhatIsBelow() {
        var doc = document()
        // The blank world's floor has its top at 0.
        let high = doc.addPart(.block, at: Vec3(10, 10, 10))
        let shelf = doc.addPart(.platform, at: Vec3(20, 3, 20))
        let onShelf = doc.addPart(.block, at: Vec3(20, 9, 20))
        let overVoid = doc.addPart(.block, at: Vec3(200, 9, 200))
        doc.selection = [high, onShelf, overVoid]
        doc.dropToGround()
        XCTAssertEqual(doc.world.worldBounds(of: high)!.min.y, 0, accuracy: 0.001)
        XCTAssertEqual(doc.world.worldBounds(of: onShelf)!.min.y, doc.world.worldBounds(of: shelf)!.max.y, accuracy: 0.001)
        XCTAssertEqual(doc.world.worldPosition(of: overVoid).y, 9, accuracy: 0.001, "nothing below: stays")
    }

    // MARK: Names

    func testRenameInOrderAlongTheLongestSide() {
        var doc = document()
        let c = doc.addPart(.orb, at: Vec3(8, 1, 0))
        let a = doc.addPart(.orb, at: Vec3(-8, 1, 0))
        let b = doc.addPart(.orb, at: Vec3(0, 1, 0.5))
        doc.selection = [a, b, c]
        doc.renameInOrder("  Coin ")
        XCTAssertEqual(doc.world.block(id: a)?.name, "Coin 1")
        XCTAssertEqual(doc.world.block(id: b)?.name, "Coin 2")
        XCTAssertEqual(doc.world.block(id: c)?.name, "Coin 3")
    }

    // MARK: Remembered selections and spots

    func testSelectionSets() throws {
        var doc = document()
        let a = doc.addPart(.block, at: Vec3(5, 1, 0))
        let b = doc.addPart(.block, at: Vec3(9, 1, 0))
        var sets = SelectionSets()
        XCTAssertFalse(sets.save("  ", ids: [a]))
        XCTAssertFalse(sets.save("Empty", ids: []))
        XCTAssertTrue(sets.save("Pair", ids: [a, b]))
        doc.selection = [b]
        doc.deleteSelection()
        XCTAssertEqual(sets.ids("Pair", in: doc.world), [a], "deleted parts are skipped")
        let data = try JSONEncoder().encode(sets)
        XCTAssertEqual(try JSONDecoder().decode(SelectionSets.self, from: data), sets)
        for index in 0..<30 { sets.save("Set \(index)", ids: [a]) }
        XCTAssertEqual(sets.names.count, SelectionSets.maximum)
        sets.remove("Pair")
        XCTAssertFalse(sets.names.contains("Pair"))
    }

    func testCameraBookmarks() throws {
        var marks = CameraBookmarks()
        let spot = CameraBookmarks.Spot(target: Vec3(1, 2, 3), yaw: 45, pitch: -20, distance: 12)
        marks.save(spot, in: 1)
        marks.save(spot, in: 9)
        XCTAssertEqual(marks.spot(1), spot)
        XCTAssertNil(marks.spot(0))
        XCTAssertNil(marks.spot(9))
        let data = try JSONEncoder().encode(marks)
        XCTAssertEqual(try JSONDecoder().decode(CameraBookmarks.self, from: data), marks)
        XCTAssertEqual(try JSONDecoder().decode(CameraBookmarks.self, from: Data("{}".utf8)).spots.count, CameraBookmarks.slots)
    }

    // MARK: Script lines

    private typealias Tools = ScriptLineTools

    func testToggleCommentOnAndOff() {
        let text = "on start\n  print(1)\n\n  print(2)\nend"
        // Lines 2 to 4 selected.
        let start = (text as NSString).range(of: "  print(1)").location
        let end = (text as NSString).range(of: "print(2)").location + 3
        let on = Tools.toggleComment(text, selection: .init(location: start, length: end - start))
        XCTAssertEqual(on.text, "on start\n  -- print(1)\n\n  -- print(2)\nend")
        let off = Tools.toggleComment(on.text, selection: on.selection)
        XCTAssertEqual(off.text, text)
        // The cursor on one line.
        let one = Tools.toggleComment("x = 1\ny = 2", selection: .init(location: 7))
        XCTAssertEqual(one.text, "x = 1\n-- y = 2")
        XCTAssertEqual(Tools.toggleComment("# note", selection: .init(location: 0)).text, "note")
    }

    func testDuplicateAndMoveLines() throws {
        let text = "a\nbb\nccc"
        let copied = Tools.duplicateLines(text, selection: .init(location: 3))
        XCTAssertEqual(copied.text, "a\nbb\nbb\nccc")
        XCTAssertEqual(copied.selection.location, 6, "on the copy")

        let up = try XCTUnwrap(Tools.moveLines(text, selection: .init(location: 3), up: true))
        XCTAssertEqual(up.text, "bb\na\nccc")
        XCTAssertEqual(up.selection.location, 1)
        XCTAssertNil(Tools.moveLines(text, selection: .init(location: 0), up: true))
        let down = try XCTUnwrap(Tools.moveLines(text, selection: .init(location: 0, length: 3), up: false))
        XCTAssertEqual(down.text, "ccc\na\nbb")
        XCTAssertNil(Tools.moveLines(text, selection: .init(location: 7), up: false))
    }

    func testCommentsAndNotes() {
        XCTAssertEqual(Tools.withoutComment("x = 1 -- set x"), "x = 1 ")
        XCTAssertEqual(Tools.withoutComment("say(\"# not a comment\") # but this is"), "say(\"# not a comment\") ")
        XCTAssertEqual(Tools.withoutComment("plain"), "plain")
        XCTAssertEqual(Tools.withoutComment("say(“-- still text”) -- note"), "say(“-- still text”) ")
        XCTAssertEqual(Tools.withoutComment("say(\"a \\\" # b\") # c"), "say(\"a \\\" # b\") ")
        let file = ScriptFile(name: "main", source: "x = 1 -- TODO: faster\nsay(\"TODO in a string\")\n# あとで ボスを追加")
        let notes = Tools.notes(in: [file])
        XCTAssertEqual(notes.map(\.line), [1, 3])
        XCTAssertEqual(notes.first?.preview, "TODO: faster")
        XCTAssertEqual(Tools.lineCount(file.source), 3)
    }
}
