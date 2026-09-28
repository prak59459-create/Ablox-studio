import XCTest
@testable import AbloxCore

/// The standard library's second round (`ScriptStandardLibraryMore.swift`).
final class ScriptHelpersTests: XCTestCase {

    private func run(_ source: String) throws -> [String] {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse(source), limits: .init())
        try interpreter.start()
        return interpreter.drainOutput()
    }

    private func error(_ source: String) -> ScriptError? {
        do {
            _ = try run(source)
            return nil
        } catch let error as ScriptError {
            return error
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    // MARK: Maths

    func testWholeNumbersAveragesAndMedians() throws {
        XCTAssertEqual(try run(#"""
        print(int(3.9), int(-3.9), int("12.7"), int("x"))
        print(average([1, 2, 3, 4]), average([]))
        print(median([5, 1, 3]), median([4, 1, 3, 2]))
        print(gcd(12, 18), gcd(-4, 6), gcd(0, 5))
        """#), ["3 -3 12 nil", "2.5 nil", "3 2.5", "6 2 5"])
    }

    func testEasingAndRanges() throws {
        XCTAssertEqual(try run(#"""
        print(smoothstep(0, 10, 5), smoothstep(0, 10, -1), smoothstep(0, 10, 20))
        print(inverse_lerp(10, 20, 15), inverse_lerp(3, 3, 9), remap(5, 0, 10, 100, 200))
        """#), ["0.5 0 1", "0.5 0 150"])
    }

    func testApproachWrapSnapAndTurning() throws {
        XCTAssertEqual(try run(#"""
        print(approach(0, 10, 3), approach(9, 10, 3), approach(10, 0, 4))
        print(approach(vec(0, 0, 0), vec(10, 0, 0), 4), approach(vec(0, 0, 0), vec(1, 0, 0), 4))
        print(wrap(370, 0, 360), wrap(-1, 0, 4), wrap(5, 1, 4))
        print(snap(7.3, 2), snap(7, 0), snap(vec(1.2, 3.9, -0.4), 1))
        print(angle_diff(350, 10), angle_diff(10, 350), angle_diff(0, 180), angle_diff(0, -180), angle_diff(720, 1))
        """#), [
            "3 10 6",
            "{x: 4, y: 0, z: 0} {x: 1, y: 0, z: 0}",
            "10 3 2",
            "8 7 {x: 1, y: 4, z: 0}",
            "20 -20 180 180 1"
        ])
    }

    func testChanceAndWeightedPicks() throws {
        XCTAssertEqual(try run(#"""
        let never = 0
        let always = 0
        let inside = true
        for i in 1 to 200 do
          if chance(0) then never = never + 1 end
          if chance(100) then always = always + 1 end
          let f = random_float(1, 2)
          if f < 1 or f > 2 then inside = false end
        end
        print(never, always, inside)
        print(pick_weighted({a: 0, b: 5}), pick_weighted([0, 0, 1]), pick_weighted({}), pick_weighted([0, -3]))
        let seen = {}
        for i in 1 to 200 do seen[pick_weighted({red: 1, blue: 1})] = true end
        print(len(seen))
        """#), ["0 200 true", "b 3 nil nil", "2"])
    }

    // MARK: Lists

    func testTidyingLists() throws {
        XCTAssertEqual(try run(#"""
        print(unique([1, 2, 1, "a", "a", 3]))
        let l = [1]
        print(len(unique([l, l, [1]])))
        print(flatten([[1, 2], 3, [4]]))
        print(zip(["a", "b", "c"], [1, 2]))
        print(first([7, 8]), last([7, 8]), first([]))
        print(chunk([1, 2, 3, 4, 5], 2))
        print(repeat("ab", 3), repeat(0, 3), len(repeat("x", 0)))
        """#), [
            #"[1, 2, "a", 3]"#,
            "2",
            "[1, 2, 3, 4]",
            #"[["a", 1], ["b", 2]]"#,
            "7 8 nil",
            "[[1, 2], [3, 4], [5]]",
            "ababab [0, 0, 0] 0"
        ])
    }

    func testAskingListsWithFunctions() throws {
        XCTAssertEqual(try run(#"""
        func even(x) return x % 2 == 0 end
        print(find([1, 3, 4, 6], even), find([1, 3], even))
        print(any([1, 3], even), all([2, 4], even), all([], even))
        print(reduce([1, 2, 3], func(a, b) return a + b end, 10), reduce([1, 2, 3], func(a, b) return a * b end))
        print(count([1, 2, 1], 1), count([1, 2, 3, 4], even), count("banana", "an"))
        let people = [{name: "A", age: 9}, {name: "B", age: 7}, {name: "C", age: 9}]
        print(min_by(people, func(p) return p.age end).name, max_by(people, func(p) return p.age end).name)
        print(map(sort_by(people, func(p) return p.age end), func(p) return p.name end))
        let groups = group_by(people, func(p) return p.age end)
        print(keys(groups), len(groups["9"]))
        """#), [
            "4 nil",
            "false true true",
            "16 6",
            "2 2 2",
            "B A",
            #"["B", "A", "C"]"#,
            #"["9", "7"] 2"#
        ])
    }

    func testSortingByAKeyThatCannotBeComparedIsAnError() {
        let failure = error(#"sort_by([1, 2], func(x) if x == 1 then return "a" end return 2 end)"#)
        XCTAssertEqual(failure?.kind, .runtime)
        XCTAssertEqual(failure?.line, 1)
    }

    func testAFunctionThatNeverEndsInsideFindStillStops() {
        var limits = ScriptInterpreter.Limits()
        limits.stepsPerCall = 5_000
        let interpreter = ScriptInterpreter(program: try! ScriptParser.parse(#"""
        func forever(x)
          while true do end
        end
        on tick(dt)
          find([1, 2], forever)
        end
        """#), limits: limits)
        XCTAssertNoThrow(try interpreter.start())
        XCTAssertThrowsError(try interpreter.run("tick", [.number(0.1)]))
    }

    // MARK: Maps and text

    func testMaps() throws {
        XCTAssertEqual(try run(#"""
        let m = {gold: 5, gems: 2}
        print(values(m), entries(m))
        let both = merge(m, {gems: 9, coins: 1})
        print(both, m)
        print(get(m, "gold", 0), get(m, "silver", 0), get(nil, "x", "none"), get([4, 5], 2, 0), get([4, 5], 3, 0))
        """#), [
            #"[5, 2] [["gold", 5], ["gems", 2]]"#,
            "{gold: 5, gems: 9, coins: 1} {gold: 5, gems: 2}",
            "5 0 none 5 0"
        ])
        XCTAssertNotNil(error("values([1, 2])"))
    }

    func testText() throws {
        XCTAssertEqual(try run(#"""
        print(pad_left(7, 3, "0"), pad_right("ab", 4, ".") + "|", pad_left("long", 2))
        print(capitalize("hello world"), len(capitalize("")))
        print(words("  one two\nthree "))
        print(lines("a\n\nb"))
        print(format("{} has {} coins", "Mika", 5), format("{} and {}", 1))
        """#), [
            "007 ab..| long",
            "Hello world 0",
            #"["one", "two", "three"]"#,
            #"["a", "", "b"]"#,
            "Mika has 5 coins 1 and {}"
        ])
    }

    func testNumbersTheWayGamesShowThem() throws {
        XCTAssertEqual(try run(#"""
        print(comma(1234567), comma(-1234.5), comma(999), comma(0))
        print(short_number(950), short_number(1500), short_number(2345678), short_number(999960), short_number(-4000000000))
        print(short_number(10000000000000), short_number(999.96), short_number(12.34))
        print(time_text(65), time_text(3661), time_text(-5), time_text(59.9))
        """#), [
            "1,234,567 -1,234.5 999 0",
            "950 1.5K 2.3M 1M -4B",
            "10T 1K 12.3",
            "1:05 1:01:01 0:00 0:59"
        ])
    }

    // MARK: Directions and colours

    func testDirections() throws {
        XCTAssertEqual(try run(#"""
        let o = vec(0, 0, 0)
        print(forward(0), forward(90), forward(180))
        print(yaw_to(o, vec(5, 0, 0)), yaw_to(o, vec(0, 0, -3)), yaw_to(o, vec(0, 0, 3)), yaw_to(o, o))
        print(rotate_y(forward(0), 90), rotate_y(vec(1, 2, 0), -90))
        print(angle_between(vec(1, 0, 0), vec(0, 0, 1)), angle_between(vec(1, 0, 0), o))
        print(direction(o, vec(0, 0, -5)))
        """#), [
            "{x: 0, y: 0, z: -1} {x: 1, y: 0, z: 0} {x: 0, y: 0, z: 1}",
            "90 0 180 0",
            "{x: 1, y: 0, z: 0} {x: 0, y: 2, z: -1}",
            "90 0",
            "{x: 0, y: 0, z: -1}"
        ])
    }

    /// `forward` and `yaw_to` agree with the way a player's `look` points.
    func testForwardMatchesYawTo() throws {
        let lines = try run(#"""
        for yaw in [0, 30, 90, 135, -60] do
          print(round(yaw_to(vec(0, 0, 0), forward(yaw))))
        end
        """#)
        XCTAssertEqual(lines, ["0", "30", "90", "135", "-60"])
    }

    func testColours() throws {
        XCTAssertEqual(try run(#"""
        print(rgb(255, 128, 0), rgb(0, 0, 0, 0.5), rgb(300, -5, 0))
        print(hsv(120, 1, 1), hsv(0, 0, 1), hsv(360, 1, 1), hsv(-120, 1, 1))
        print(mix_color("#000000", "#FFFFFF", 0.5), mix_color("red", "blue", 0))
        let c = random_color()
        print(starts_with(c, "#"), len(c))
        """#), [
            "#FF8000 #00000080 #FF0000",
            "#00FF00 #FFFFFF #FF0000 #0000FF",
            "#808080 #EF4444",
            "true 7"
        ])
        XCTAssertTrue(error(#"mix_color("nope", "red", 1)"#)?.message.contains("nope") ?? false)
    }

    // MARK: Everything is listed

    func testEveryNewNameIsAFunction() throws {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse(""), limits: .init())
        for name in ScriptInterpreter.moreStandardLibraryNames {
            guard case .native = interpreter.globals.lookup(name) ?? .null else {
                return XCTFail("\(name) is not defined")
            }
        }
        XCTAssertEqual(Set(ScriptInterpreter.standardLibraryNames).count, ScriptInterpreter.standardLibraryNames.count,
                       "no name is listed twice")
    }

    /// A creator's own variable called `count` or `first` shows while
    /// paused, though those are also functions' names now.
    func testOwnVariablesWithBuiltInNamesAreShownWhilePaused() throws {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse("let count = 3\nlet first = [1]"), limits: .init())
        try interpreter.start()
        let hidden = Set(ScriptInterpreter.standardLibraryNames)
        let names = BreakpointHit.variables(in: interpreter.globals, hiding: hidden).map(\.name)
        XCTAssertTrue(names.contains("count"))
        XCTAssertTrue(names.contains("first"))
        XCTAssertFalse(names.contains("pi"))
        XCTAssertFalse(names.contains("len"))
    }

    // MARK: Numbers that used to stop the app

    /// nan and enormous numbers as positions, counts and digits: each was
    /// `Int(_:)` of a Double, which stops the whole app rather than the
    /// script.
    func testNanAndHugeNumbersNeverStopTheApp() throws {
        XCTAssertEqual(try run(#"""
        let l = [1, 2, 3]
        let huge = pow(10, 300)
        let inf = exp(700) * exp(700)
        print(l[huge], l[inf], l[sqrt(-1)], "abc"[huge])
        print(slice(l, 1, huge), slice(l, sqrt(-1)), slice("abc", 2, inf))
        insert(l, sqrt(-1), 0)
        print(l, remove(l, huge))
        print(round(1.5, sqrt(-1)), fixed(2.5, inf))
        print(random(1, huge) >= 1, random(sqrt(-1), 3) >= 0)
        print(pad_left("a", huge, "-") == nil, chunk([1, 2], huge))
        """#), [
            "nil nil nil nil",
            "[1, 2, 3] [1, 2, 3] bc",
            "[0, 1, 2, 3] nil",
            "2 2.5000000000",
            "true true",
            "false [[1, 2]]"
        ])
        XCTAssertEqual(error("range(1, exp(700) * exp(700))")?.kind, .limit)
        XCTAssertEqual(error("range(1, pow(10, 300))")?.kind, .limit)
        XCTAssertEqual(error("range(sqrt(-1), 5)")?.kind, .limit)
        XCTAssertEqual(error(#"repeat("a", pow(10, 300))"#)?.kind, .limit)
        XCTAssertEqual(error("repeat(0, pow(10, 300))")?.kind, .limit)
    }
}

/// The game's own searches (`GameRuntimeHelpers.swift`).
final class GameHelperTests: RuntimeTestCase {

    private func coinWorld() -> WorldDocument {
        var world = WorldDocument(name: "Coins")
        for (name, x, tags) in [("CoinA", Float(3), ["coin"]), ("CoinB", 1, ["coin"]), ("Rock", 0.4, [])] {
            var block = BlockData(name: name, transform: Transform3D(position: Vec3(x, 0, 0), scale: Vec3(0.2, 0.2, 0.2)))
            block.tags = tags
            world.insert(block)
        }
        return world
    }

    func testFindingPlayersAndBlocks() {
        let game = game(#"""
        on join(p)
          if p.name == "Alice" then
            p.team = "red"
            p.score = 3
            p.ui_button("go", "Go")
          else
            p.team = "blue"
            p.score = 7
          end
        end
        on button(p, id)
          print(nearest_player(p).name, nearest_player(p, 5))
          print(len(players_near(p, 5)), len(players_near(p, 50)))
          print(nearest_player({x: 100, y: 0, z: 0}).name)
          print(team_players("red")[1].name, len(team_players("green")))
          print(map(ranking(), func(q) return q.name end))
          print(random_player() != nil, len(alive_players()))
          print(nearest_block(p, "coin").name, nearest_block(p).name, nearest_block(block("CoinB"), "coin").name)
          print(map(blocks_near(p, 10, "coin"), func(b) return b.name end), len(blocks_near(p, 2, "coin")))
          print(direction(p, block("CoinA")), yaw_to(p, block("CoinA")))
        end
        """#, world: coinWorld())
        startWithBoth(game)
        place(game, alice, at: .zero)
        place(game, bob, at: Vec3(10, 0, 0))
        _ = game.handle(.button(id: "go"), from: alice, at: 1)
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        XCTAssertEqual(game.drainOutput(), [
            "Bob nil",
            "0 1",
            "Bob",
            "Alice 0",
            #"["Bob", "Alice"]"#,
            "true 2",
            "CoinB Rock CoinA",
            #"["CoinB", "CoinA"]"# + " 1",
            "{x: 1, y: 0, z: 0} 90"
        ])
    }

    func testAKnockedOutPlayerIsNotNearestOrAlive() {
        let game = game(#"""
        on join(p)
          p.ui_button("ko", "Knock out")
          p.ui_button("look", "Look")
        end
        on button(p, id)
          if id == "ko" then
            find_player("Bob").kill()
          else
            print(nearest_player(p), len(alive_players()), len(players_near(p, 100)))
          end
        end
        """#)
        startWithBoth(game)
        place(game, alice, at: .zero)
        place(game, bob, at: Vec3(2, 0, 0))
        _ = game.handle(.button(id: "ko"), from: alice, at: 1)
        _ = game.handle(.button(id: "look"), from: alice, at: 1.5)
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        XCTAssertEqual(game.drainOutput(), ["nil 1 0"])
    }

    func testEveryHelperIsInTheReference() {
        let code = ScriptReference.sections.flatMap(\.entries).map(\.code).joined(separator: "\n")
        for name in GameRuntime.helperAPINames + ScriptInterpreter.moreStandardLibraryNames {
            XCTAssertNotNil(code.range(of: "\\b\(name)\\(", options: .regularExpression), "\(name) is missing")
        }
    }
}
