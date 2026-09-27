import XCTest
@testable import AbloxCore

/// The ready-made worlds and parts, and the test run's new tools.
final class WorldTemplateTests: XCTestCase {

    private var templates: [WorldDocument] {
        [WorldTemplates.obby(named: "Obby"), WorldTemplates.race(named: "Race"),
         WorldTemplates.battle(named: "Battle"), WorldTemplates.tycoon(named: "Tycoon")]
    }

    func testEveryTemplateRunsCleanly() {
        for world in templates {
            XCTAssertTrue(GameRuntime.check(world.scripts).isEmpty, "\(world.name): \(GameRuntime.check(world.scripts))")
            let report = GameRuntime.testRun(world: world, seconds: 8, robots: true)
            XCTAssertTrue(report.isClean, "\(world.name): \(report.problems)")
            XCTAssertFalse(world.spawnBlocks.isEmpty, "\(world.name) has nowhere to start")
            XCTAssertTrue(world.validate().isEmpty, "\(world.name): \(world.validate())")
        }
    }

    func testTemplatesSurviveSaving() throws {
        for world in templates {
            let decoded = try WorldDocument.decoded(from: world.encodedForFile())
            XCTAssertEqual(decoded.blocks.count, world.blocks.count)
            XCTAssertEqual(decoded.scripts, world.scripts)
        }
    }

    func testTheLibraryHasItsParts() {
        let library = PrefabLibrary.builtIn
        XCTAssertGreaterThanOrEqual(library.count, 12)
        XCTAssertEqual(Set(library.map(\.id)).count, library.count, "each built-in part keeps its own id")
        XCTAssertEqual(library.map(\.id), PrefabLibrary.builtIn.map(\.id), "and the same id every time")
        for prefab in library {
            XCTAssertFalse(prefab.blocks.isEmpty)
            // Coins float to be collected; turned wheels are round, whatever
            // their unturned box says.
            guard !prefab.blocks.allSatisfy({ $0.behavior == .collectible }) else { continue }
            let upright = prefab.blocks.filter { $0.rotationDegrees == .zero }
            let lowest = upright.map { $0.localBounds.min.y }.min() ?? 0
            XCTAssertLessThanOrEqual(lowest, 0.5, "\(prefab.name) should stand on the ground")
            XCTAssertGreaterThanOrEqual(lowest, -0.05, "\(prefab.name) should not sink into it")
        }
        XCTAssertTrue(library.contains { $0.blocks.contains { $0.light != nil } }, "a lamp")
        XCTAssertTrue(library.contains { $0.blocks.contains { $0.behavior == .vehicle } }, "a car to drive")
    }

    func testBreakpointsShowTheVariables() {
        var world = WorldDocument(name: "Debug")
        world.scripts = [ScriptFile(name: "main", source: """
        let total = 0
        on start()
          for i in 1 to 3 do
            total = total + i
          end
          print(total)
        end
        """)]
        let report = GameRuntime.testRun(world: world, seconds: 1, breakpoints: [ScriptBreakpoint(file: "main.absc", line: 6)])
        XCTAssertEqual(report.output, ["6"])
        let hit = try? XCTUnwrap(report.hits.first)
        XCTAssertEqual(hit?.line, 6)
        XCTAssertTrue(hit?.variables.contains { $0.name == "total" && $0.value == "6" } ?? false, "\(String(describing: hit))")
        XCTAssertFalse(hit?.variables.contains { $0.name == "print" } ?? true, "built-ins are left out")
    }

    func testTheHeavyHandlerIsNamed() {
        var world = WorldDocument(name: "Heavy")
        world.scripts = [ScriptFile(name: "main", source: """
        on tick(dt)
          let n = 0
          for i in 1 to 2000 do n = n + i end
        end
        on join(p)
          p.coins = 1
        end
        """)]
        let report = GameRuntime.testRun(world: world, seconds: 1)
        XCTAssertEqual(report.costs.first?.name, "on tick")
        XCTAssertGreaterThan(report.costs.first?.calls ?? 0, 5)
        XCTAssertTrue(report.costs.contains { $0.name == "on join" && $0.calls == 2 })
    }

    func testRobotsPressButtonsAndTouchParts() {
        var world = WorldDocument(name: "Robots")
        world.blocks = [BlockData(name: "Pad", behavior: .trigger)]
        world.scripts = [ScriptFile(name: "main", source: """
        on join(p)
          p.ui_button("go", "Go")
        end
        on button(p, id)
          print("pressed " + id)
        end
        on touch(p, b)
          print("touched " + b.name)
        end
        """)]
        let idle = GameRuntime.testRun(world: world, seconds: 2)
        XCTAssertTrue(idle.output.isEmpty)
        let played = GameRuntime.testRun(world: world, seconds: 2, robots: true)
        XCTAssertTrue(played.output.contains("pressed go"), "\(played.output)")
        XCTAssertTrue(played.output.contains("touched Pad"), "\(played.output)")
        XCTAssertFalse(played.robotNotes.isEmpty)
    }

    func testCodeIsColoured() {
        let spans = ScriptHighlighter.spans(in: "on join(p) -- hi\n  let x = \"end\" + 12\nend", builtins: ["print"])
        let kinds = spans.map(\.kind)
        XCTAssertEqual(kinds, [.keyword, .event, .comment, .keyword, .string, .number, .keyword])
        XCTAssertEqual(ScriptHighlighter.range(ofLine: 2, in: "a\nbc\nd"), NSRange(location: 2, length: 2))
        XCTAssertNil(ScriptHighlighter.range(ofLine: 9, in: "a"))
    }

    func testLampsAndLocksAreKept() throws {
        var block = BlockData(name: "Lamp")
        block.light = BlockLight(kind: .spot, intensity: 9, range: 999)
        block.isLocked = true
        block.layer = "Lights"
        XCTAssertEqual(block.light?.intensity, 1)
        XCTAssertEqual(block.light?.range, 50)
        let decoded = try JSONDecoder().decode(BlockData.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(decoded, block)
        let plain = String(decoding: try JSONEncoder().encode(BlockData(name: "Plain")), as: UTF8.self)
        XCTAssertFalse(plain.contains("locked"), "an unlocked block does not carry the flag")
        XCTAssertFalse(block.needsSchema2, "an older iPad just shows the block unlit")
    }
}
