import XCTest
@testable import AbloxCore

/// AbloxScript: the language, before any game is attached to it.
final class ScriptLanguageTests: XCTestCase {

    /// Runs a script's top level and returns what it printed.
    private func run(_ source: String, limits: ScriptInterpreter.Limits = .init()) throws -> [String] {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse(source), limits: limits)
        try interpreter.start()
        return interpreter.drainOutput()
    }

    private func error(_ source: String, limits: ScriptInterpreter.Limits = .init()) -> ScriptError? {
        do {
            _ = try run(source, limits: limits)
            return nil
        } catch let error as ScriptError {
            return error
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    // MARK: Values and arithmetic

    func testArithmetic() throws {
        XCTAssertEqual(try run("print(1 + 2 * 3)"), ["7"])
        XCTAssertEqual(try run("print((1 + 2) * 3)"), ["9"])
        XCTAssertEqual(try run("print(7 / 2)"), ["3.5"], "division is never integer division")
        XCTAssertEqual(try run("print(-1 % 4)"), ["3"], "floored remainder, for wrapping an index")
        XCTAssertEqual(try run("print(-(2 + 3))"), ["-5"])
    }

    func testWholeNumbersPrintWithoutADecimalPoint() throws {
        XCTAssertEqual(try run("print(10)"), ["10"])
        XCTAssertEqual(try run("print(0.1 + 0.2)"), ["0.3"])
    }

    func testPlusJoinsTextWhenEitherSideIsText() throws {
        // "Score: " + score is what everyone writes first.
        XCTAssertEqual(try run(#"print("Score: " + 5)"#), ["Score: 5"])
        XCTAssertEqual(try run(#"print(5 + " points")"#), ["5 points"])
        XCTAssertEqual(try run(#"print("a" .. "b" .. 1)"#), ["ab1"])
    }

    func testComparisonAndLogic() throws {
        XCTAssertEqual(try run("print(1 < 2, 2 <= 2, 3 > 4, 1 == 1, 1 != 1)"), ["true true false true false"])
        XCTAssertEqual(try run("print(true and false, true or false, not true)"), ["false true false"])
    }

    func testOrGivesADefault() throws {
        // The idiom `name or "Guest"` needs `or` to return an operand.
        XCTAssertEqual(try run(#"let name = nil\#nprint(name or "Guest")"#), ["Guest"])
    }

    func testOnlyNilAndFalseAreFalse() throws {
        XCTAssertEqual(try run(#"if 0 then print("zero is true") end"#), ["zero is true"])
        XCTAssertEqual(try run(#"if "" then print("empty text is true") end"#), ["empty text is true"])
        XCTAssertEqual(try run(#"if nil then print("x") else print("nil is false") end"#), ["nil is false"])
    }

    func testDivisionByZeroIsAnErrorNotInfinity() {
        XCTAssertEqual(error("print(1 / 0)")?.kind, .runtime)
        XCTAssertEqual(error("print(1 % 0)")?.kind, .runtime)
    }

    // MARK: Variables and scope

    func testVariables() throws {
        XCTAssertEqual(try run("let x = 1\nx = x + 1\nprint(x)"), ["2"])
    }

    func testAssigningAnUndeclaredNameIsAnError() {
        // The usual cause is a typo, and a silently created second variable
        // is the hardest kind of bug for a beginner to find.
        let failure = error("let score = 0\nscroe = 1")
        XCTAssertEqual(failure?.line, 2)
        XCTAssertTrue(failure?.message.contains("score") ?? false, "should suggest the real name: \(failure?.message ?? "")")
    }

    func testReadingAnUndefinedNameSuggestsTheRealOne() {
        let failure = error("let players = 3\nprint(palyers)")
        XCTAssertTrue(failure?.message.contains("players") ?? false, failure?.message ?? "")
    }

    func testASuggestionIsNotMadeForSomethingUnrelated() {
        let failure = error("print(zebra)")
        XCTAssertNotNil(failure)
        XCTAssertFalse(failure?.message.contains("Did you mean") ?? true)
    }

    func testBlocksHaveTheirOwnScope() throws {
        XCTAssertEqual(try run("""
        let x = 1
        if true then
            let x = 2
            print(x)
        end
        print(x)
        """), ["2", "1"])
    }

    func testIdentifiersMayBeInAnyScript() throws {
        XCTAssertEqual(try run("let 体力 = 100\n体力 = 体力 - 30\nprint(体力)"), ["70"])
    }

    // MARK: Control flow

    func testIfElifElse() throws {
        let source = """
        func grade(n)
            if n >= 90 then return "A"
            elif n >= 50 then return "B"
            else return "C" end
        end
        print(grade(95), grade(60), grade(10))
        """
        XCTAssertEqual(try run(source), ["A B C"])
    }

    func testWhileWithBreakAndContinue() throws {
        let source = """
        let i = 0
        let seen = []
        while true do
            i = i + 1
            if i == 3 then continue end
            if i > 5 then break end
            append(seen, i)
        end
        print(seen)
        """
        XCTAssertEqual(try run(source), ["[1, 2, 4, 5]"])
    }

    func testForRangeIsInclusiveAndCountsDownOnItsOwn() throws {
        XCTAssertEqual(try run("for i in 1 to 3 do print(i) end"), ["1", "2", "3"])
        XCTAssertEqual(try run("for i in 3 to 1 do print(i) end"), ["3", "2", "1"],
                       "counting down should not need `step -1`")
        XCTAssertEqual(try run("for i in 0 to 10 step 5 do print(i) end"), ["0", "5", "10"])
    }

    func testAStepOfZeroIsRefused() {
        XCTAssertEqual(error("for i in 1 to 5 step 0 do end")?.kind, .runtime)
    }

    func testForEachOverListsMapsAndText() throws {
        XCTAssertEqual(try run("for x in [10, 20] do print(x) end"), ["10", "20"])
        XCTAssertEqual(try run("for k in { a: 1, b: 2 } do print(k) end"), ["a", "b"], "maps iterate in written order")
        XCTAssertEqual(try run(#"for c in "hi" do print(c) end"#), ["h", "i"])
    }

    func testAddingToAListInsideItsOwnLoopDoesNotRunForever() throws {
        XCTAssertEqual(try run("""
        let items = [1, 2]
        for x in items do append(items, x) end
        print(len(items))
        """), ["4"])
    }

    // MARK: Functions

    func testFunctionsAndRecursion() throws {
        XCTAssertEqual(try run("""
        func fact(n)
            if n <= 1 then return 1 end
            return n * fact(n - 1)
        end
        print(fact(5))
        """), ["120"])
    }

    func testClosuresCaptureTheirScope() throws {
        XCTAssertEqual(try run("""
        func counter()
            let n = 0
            return func()
                n = n + 1
                return n
            end
        end
        let next = counter()
        next()
        print(next())
        """), ["2"])
    }

    func testMissingArgumentsAreNilAndExtraOnesIgnored() throws {
        XCTAssertEqual(try run("""
        func f(a, b) print(a, b) end
        f(1)
        f(1, 2, 3)
        """), ["1 nil", "1 2"])
    }

    // MARK: Lists and maps

    func testListsCountFromOne() throws {
        // As in Scratch, which is where most children will have seen a list.
        XCTAssertEqual(try run("let l = [10, 20, 30]\nprint(l[1], l[3], l.length)"), ["10 30 3"])
    }

    func testReadingPastTheEndIsNilWritingPastTheEndIsAnError() {
        XCTAssertEqual(try? run("let l = [1]\nprint(l[5])"), ["nil"])
        let failure = error("let l = [1]\nl[5] = 2")
        XCTAssertTrue(failure?.message.contains("append") ?? false, "should say how to add an item")
    }

    func testListsAreShared() throws {
        XCTAssertEqual(try run("""
        func add(list) append(list, 3) end
        let mine = [1, 2]
        add(mine)
        print(mine)
        """), ["[1, 2, 3]"])
    }

    func testMaps() throws {
        XCTAssertEqual(try run("""
        let p = { hp: 100, name: "Mika" }
        p.hp = p.hp - 25
        p["team"] = "red"
        print(p.hp, p.name, p.team, p.missing)
        """), ["75 Mika red nil"])
    }

    func testStandardLibrary() throws {
        XCTAssertEqual(try run(#"print(len([1,2,3]), floor(2.7), max(1, 9, 4), clamp(15, 0, 10))"#), ["3 2 9 10"])
        XCTAssertEqual(try run(#"print(join(split("a,b,c", ","), "-"), upper("ab"), contains([1,2], 2))"#), ["a-b-c AB true"])
        XCTAssertEqual(try run(#"print(num("12") + 1, num("twelve"))"#), ["13 nil"])
    }

    func testRandomIsSeededAndInRange() throws {
        let first = try run("for i in 1 to 5 do print(random(1, 6)) end")
        let second = try run("for i in 1 to 5 do print(random(1, 6)) end")
        XCTAssertEqual(first, second, "the same seed gives the same rolls, so a game can be replayed")
        for value in first {
            XCTAssertTrue((1...6).contains(Int(value)!), value)
        }
    }

    // MARK: The limits

    func testAnInfiniteLoopIsStopped() {
        // The reason this language exists instead of JavaScriptCore: a
        // script from the catalogue must not be able to freeze the host.
        let failure = error("while true do end")
        XCTAssertEqual(failure?.kind, .limit)
        XCTAssertEqual(failure?.line, 1)
    }

    func testAnInfiniteLoopInsideAFunctionIsStopped() {
        XCTAssertEqual(error("func spin() while true do let x = 1 end end\nspin()")?.kind, .limit)
    }

    func testInfiniteRecursionIsStoppedBeforeTheStackOverflows() {
        let failure = error("func forever(n) return forever(n + 1) end\nforever(1)")
        XCTAssertEqual(failure?.kind, .limit)
        XCTAssertTrue(failure?.message.contains("forever") ?? false, "should name the function")
    }

    func testAListCannotGrowWithoutLimit() {
        var limits = ScriptInterpreter.Limits()
        limits.maximumCollectionSize = 100
        limits.stepsPerCall = 1_000_000
        XCTAssertEqual(error("let l = []\nwhile true do append(l, 1) end", limits: limits)?.kind, .limit)
    }

    func testTextCannotGrowWithoutLimit() {
        var limits = ScriptInterpreter.Limits()
        limits.maximumTextLength = 1_000
        limits.stepsPerCall = 1_000_000
        XCTAssertEqual(error(#"let s = "x"\#nwhile true do s = s .. s end"#, limits: limits)?.kind, .limit)
    }

    func testTheBudgetIsPerCallNotPerScript() throws {
        // A handler that uses most of its budget must not starve the next one.
        var limits = ScriptInterpreter.Limits()
        limits.stepsPerCall = 2_000
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse("""
        on tick()
            for i in 1 to 300 do let x = i end
        end
        """), limits: limits)
        try interpreter.start()
        for _ in 0..<20 {
            XCTAssertNoThrow(try interpreter.fire("tick"))
        }
    }

    func testDeeplyNestedSourceIsRefusedByTheParser() {
        // The parser has no step budget, so nesting is limited directly.
        let source = String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)
        XCTAssertEqual(error("print(\(source))")?.kind, .limit)
    }

    func testPrintOutputIsCapped() throws {
        var limits = ScriptInterpreter.Limits()
        limits.maximumOutputLines = 10
        XCTAssertEqual(try run("for i in 1 to 100 do print(i) end", limits: limits).count, 10)
    }

    // MARK: Syntax errors that help

    func testAMissingEndNamesTheBlockThatOpenedIt() {
        let failure = error("""
        let x = 1
        if x > 0 then
            print(x)
        """)
        XCTAssertEqual(failure?.line, 2, "the line of the `if`, not the end of the file")
        XCTAssertTrue(failure?.message.contains("if") ?? false)
    }

    func testSingleEqualsInAConditionIsNamed() {
        let failure = error("let hp = 0\nif hp = 0 then end")
        XCTAssertTrue(failure?.message.contains("==") ?? false, failure?.message ?? "")
    }

    func testAnExtraEndIsNamed() {
        let failure = error("print(1)\nend")
        XCTAssertEqual(failure?.line, 2)
        XCTAssertTrue(failure?.message.contains("end") ?? false)
    }

    func testAReservedWordAsANameIsNamed() {
        XCTAssertTrue(error("let end = 1")?.message.contains("end") ?? false)
    }

    func testAnUnclosedStringPointsAtItsLine() {
        let failure = error("print(1)\nprint(\"oops)\nprint(2)")
        XCTAssertEqual(failure?.line, 2)
    }

    func testALineThatDoesNothingIsFlagged() {
        XCTAssertNotNil(error("let x = 1\nx + 1"))
    }

    func testCommentsInBothStyles() throws {
        XCTAssertEqual(try run("-- a comment\nprint(1) # another\n"), ["1"])
    }

    func testReturnOutsideAFunctionIsAnError() {
        XCTAssertNotNil(error("return 5"))
        XCTAssertNotNil(error("if true then return 5 end"))
    }

    func testBreakOutsideALoopIsAnError() {
        XCTAssertNotNil(error("func f() break end\nf()"))
    }

    // MARK: Handlers

    func testHandlersAreCalledByName() throws {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse("""
        let total = 0
        on add(n) total = total + n end
        on report() print(total) end
        """))
        try interpreter.start()
        try interpreter.fire("add", [.number(3)])
        try interpreter.fire("add", [.number(4)])
        try interpreter.fire("report")
        XCTAssertEqual(interpreter.drainOutput(), ["7"], "globals persist between events")
    }

    func testFiringAnEventWithNoHandlerIsHarmless() throws {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse("print(1)"))
        XCTAssertFalse(try interpreter.fire("nothing"))
    }

    func testTwoHandlersForOneEventAreAnError() {
        let failure = error("on tick() end\non tick() end")
        XCTAssertEqual(failure?.line, 2)
        XCTAssertTrue(failure?.message.contains("1") ?? false, "should point at the first one")
    }

    func testAHandlerInsideAFunctionIsAnError() {
        XCTAssertNotNil(error("func f()\n on tick() end\nend"))
    }

    // MARK: What an iPad keyboard actually types

    func testSmartQuotesAreQuotes() throws {
        // The iPad keyboard turns " into “ and ” while you type.
        XCTAssertEqual(try run("print(“hello”)"), ["hello"])
        XCTAssertEqual(try run("print(‘it’ + \"s\")"), ["its"])
        // Retyping only the closing quote of existing text gives one of each.
        XCTAssertEqual(try run("print(\"mixed”)"), ["mixed"])
    }

    func testFullWidthSymbolsAreRead() throws {
        // A Japanese keyboard left in full-width mode.
        XCTAssertEqual(try run("let ｘ　＝　１２\nprint（ｘ　＋　１）"), ["13"])
        XCTAssertEqual(try run("print(\"（そのまま）\")"), ["（そのまま）"], "text values keep what was typed")
    }
}
