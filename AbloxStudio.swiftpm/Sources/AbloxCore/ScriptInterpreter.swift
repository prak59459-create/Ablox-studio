import Foundation

/// Answers `player.health`, `block.visible = false` and the like.
///
/// The interpreter knows nothing about games; the runtime above it does. A
/// game object's members are therefore resolved through this, which is also
/// what keeps a script from reaching anything the runtime did not hand it.
public protocol ScriptObjectResolver: AnyObject {
    func member(of object: ScriptObject, named name: String, line: Int) throws -> ScriptValue
    func setMember(of object: ScriptObject, named name: String, to value: ScriptValue, line: Int) throws
}

/// Runs an AbloxScript program, with limits.
///
/// ## The limits are the point
///
/// Worlds arrive from strangers through the game catalogue, and scripts run on
/// the *host* — the one iPad everyone else's game depends on. So every
/// statement and expression costs a step, and a handler that spends more than
/// its budget is stopped with an error on the line it had reached. A script
/// cannot freeze the host, recurse until the stack overflows, or grow a list
/// until the iPad runs out of memory. There is no file, network or clock
/// access at all: the only way out of a script is the game API it was given.
public final class ScriptInterpreter {

    public struct Limits: Sendable {
        /// Steps per handler call. Two million is far more than any game
        /// needs in one event — a loop over ten thousand blocks is a fraction
        /// of it — and is only here as a fuse: `while true do end` must stop
        /// eventually rather than freeze the host for everyone.
        public var stepsPerCall = 2_000_000
        public var maximumCallDepth = 200
        public var maximumCollectionSize = 100_000
        public var maximumTextLength = 1_000_000
        /// `print` output kept for Studio's console.
        public var maximumOutputLines = 500

        public init() {}
    }

    public let program: ScriptProgram
    public let globals = ScriptScope(parent: nil)
    public var limits: Limits
    public weak var resolver: ScriptObjectResolver?
    public var random: ScriptRandom

    public private(set) var output: [String] = []

    private var stepsRemaining = 0
    private var callDepth = 0
    /// How many entry points are active. Separate from `callDepth`, which
    /// counts script functions: a native called straight from a handler body
    /// is at call depth 0 but still inside that handler's budget.
    private var entryDepth = 0
    /// Names the standard library and the game define, for "did you mean".
    private var builtinNames: Set<String> = []

    public init(program: ScriptProgram, seed: UInt64 = 1, limits: Limits = Limits()) {
        self.program = program
        self.random = ScriptRandom(seed: seed)
        self.limits = limits
        installStandardLibrary()
    }

    // MARK: Entry points

    /// Runs the top level once: `let` declarations, `func` definitions and
    /// anything else written outside a handler.
    public func start() throws {
        try withBudget {
            _ = try execute(program.statements, in: globals, isTopLevel: true)
        }
    }

    public func hasHandler(_ event: String) -> Bool {
        !(program.handlers[event] ?? []).isEmpty
    }

    /// Calls `on <event>(…)`, if the script has one.
    ///
    /// Missing arguments arrive as nil and extra ones are dropped, so a
    /// handler written as `on hit(attacker)` still works when the game passes
    /// three values.
    @discardableResult
    public func fire(_ event: String, _ arguments: [ScriptValue] = []) throws -> Bool {
        try run(event, arguments) != nil
    }

    /// Like `fire`, but hands back what the handlers returned: nil when there
    /// is no handler, `.null` when none returned anything, otherwise the last
    /// value one of them returned. `on hit` uses this to change the damage.
    ///
    /// Every file's handler for the event runs, in file order. Each gets its
    /// own budget: one file's heavy `on tick` must not starve another's.
    public func run(_ event: String, _ arguments: [ScriptValue] = []) throws -> ScriptValue? {
        guard let handlers = program.handlers[event], !handlers.isEmpty else { return nil }
        var result = ScriptValue.null
        for handler in handlers {
            try withBudget {
                let scope = ScriptScope(parent: globals)
                for (index, name) in handler.parameters.enumerated() {
                    scope.declare(name, index < arguments.count ? arguments[index] : .null)
                }
                let flow = try execute(handler.body, in: scope, isTopLevel: false)
                try checkFlowAtBoundary(flow, line: handler.line)
                if case let .returned(value) = flow, !value.isNull { result = value }
            }
        }
        return result
    }

    /// Calls a function value — used for timers set with `after`.
    @discardableResult
    public func invoke(_ callable: ScriptValue, _ arguments: [ScriptValue] = [], line: Int) throws -> ScriptValue {
        var result = ScriptValue.null
        try withBudget {
            result = try call(callable, arguments, line: line)
        }
        return result
    }

    /// Adds a function the script can call by name.
    public func define(_ name: String, _ body: @escaping ([ScriptValue], Int) throws -> ScriptValue) {
        globals.declare(name, .native(ScriptNative(name, body)))
        builtinNames.insert(name)
    }

    public func defineValue(_ name: String, _ value: ScriptValue) {
        globals.declare(name, value)
        builtinNames.insert(name)
    }

    /// What `print` has produced since the last call.
    public func drainOutput() -> [String] {
        defer { output.removeAll() }
        return output
    }

    public func log(_ line: String) {
        output.append(line)
        if output.count > limits.maximumOutputLines {
            output.removeFirst(output.count - limits.maximumOutputLines)
        }
    }

    private func withBudget(_ body: () throws -> Void) throws {
        // Re-entrant: a native called from a script may call back into the
        // script, and that must spend from the same budget rather than get a
        // fresh one — otherwise a callback could launder an infinite loop.
        if entryDepth == 0 {
            stepsRemaining = limits.stepsPerCall
            callDepth = 0
        }
        entryDepth += 1
        defer { entryDepth -= 1 }
        try body()
    }

    /// Steps left in the current call, for tests and for Studio's profiler.
    public var remainingSteps: Int { stepsRemaining }

    private func step(_ line: Int) throws {
        stepsRemaining -= 1
        if stepsRemaining < 0 {
            throw ScriptError(line: line, kind: .limit,
                              message: L("This took too long and was stopped. Is there a loop that never ends?"))
        }
    }

    // MARK: Statements

    private enum Flow {
        case normal
        case breakLoop(line: Int)
        case continueLoop(line: Int)
        case returned(ScriptValue)
    }

    private func checkFlowAtBoundary(_ flow: Flow, line: Int) throws {
        switch flow {
        case let .breakLoop(line):
            throw ScriptError(line: line, kind: .syntax, message: L("“break” can only be used inside a loop."))
        case let .continueLoop(line):
            throw ScriptError(line: line, kind: .syntax, message: L("“continue” can only be used inside a loop."))
        case .normal, .returned:
            break
        }
    }

    private func execute(_ statements: [ScriptStmt], in scope: ScriptScope, isTopLevel: Bool) throws -> Flow {
        for statement in statements {
            let flow = try execute(statement, in: scope, isTopLevel: isTopLevel)
            if case .normal = flow { continue }
            return flow
        }
        return .normal
    }

    private func execute(_ statement: ScriptStmt, in scope: ScriptScope, isTopLevel: Bool) throws -> Flow {
        try step(statement.line)

        switch statement.kind {
        case let .declare(name, value):
            scope.declare(name, try value.map { try evaluate($0, in: scope) } ?? .null)

        case let .assign(target, value):
            try assign(try evaluate(value, in: scope), to: target, in: scope)

        case let .expression(expression):
            _ = try evaluate(expression, in: scope)

        case let .ifChain(branches, otherwise):
            for branch in branches where try evaluate(branch.condition, in: scope).isTruthy {
                return try execute(branch.body, in: ScriptScope(parent: scope), isTopLevel: isTopLevel)
            }
            if let otherwise {
                return try execute(otherwise, in: ScriptScope(parent: scope), isTopLevel: isTopLevel)
            }

        case let .whileLoop(condition, body):
            while try evaluate(condition, in: scope).isTruthy {
                switch try execute(body, in: ScriptScope(parent: scope), isTopLevel: isTopLevel) {
                case .normal, .continueLoop: continue
                case .breakLoop: return .normal
                case let .returned(value): return .returned(value)
                }
            }

        case let .forRange(variable, fromExpression, toExpression, stepExpression, body):
            let from = try number(try evaluate(fromExpression, in: scope), what: "for", line: statement.line)
            let to = try number(try evaluate(toExpression, in: scope), what: "for", line: statement.line)
            // Counting down needs no `step -1` — `for i in 10 to 1` does what
            // it says, which is what a beginner expects it to do.
            let increment = try stepExpression.map {
                try number(try evaluate($0, in: scope), what: "step", line: statement.line)
            } ?? (from <= to ? 1 : -1)
            guard increment != 0 else {
                throw ScriptError(line: statement.line, kind: .runtime, message: L("“step” cannot be 0 — the loop would never end."))
            }

            var value = from
            while increment > 0 ? value <= to : value >= to {
                let iteration = ScriptScope(parent: scope)
                iteration.declare(variable, .number(value))
                switch try execute(body, in: iteration, isTopLevel: isTopLevel) {
                case .normal, .continueLoop: break
                case .breakLoop: return .normal
                case let .returned(result): return .returned(result)
                }
                value += increment
                try step(statement.line)
            }

        case let .forEach(variable, sequenceExpression, body):
            let items: [ScriptValue]
            switch try evaluate(sequenceExpression, in: scope) {
            case let .list(list):
                // A copy, so adding to the list inside the loop cannot make
                // the loop run forever.
                items = list.items
            case let .map(map):
                items = map.keys.map { .string($0) }
            case let .string(text):
                items = text.map { .string(String($0)) }
            case let other:
                throw ScriptError(line: statement.line, kind: .runtime,
                                  message: L("“for … in” needs a list, a map or text, not {}.", other.typeName))
            }
            for item in items {
                let iteration = ScriptScope(parent: scope)
                iteration.declare(variable, item)
                switch try execute(body, in: iteration, isTopLevel: isTopLevel) {
                case .normal, .continueLoop: continue
                case .breakLoop: return .normal
                case let .returned(result): return .returned(result)
                }
            }

        case let .function(name, parameters, body):
            scope.declare(name, .function(ScriptFunction(
                name: name, parameters: parameters, body: body, closure: scope, line: statement.line
            )))

        case .handler:
            // Collected by the parser; running the top level passes over them.
            break

        case let .returnValue(expression):
            if isTopLevel {
                throw ScriptError(line: statement.line, kind: .syntax,
                                  message: L("“return” can only be used inside a function or an “on”."))
            }
            return .returned(try expression.map { try evaluate($0, in: scope) } ?? .null)

        case .breakLoop:
            return .breakLoop(line: statement.line)

        case .continueLoop:
            return .continueLoop(line: statement.line)
        }

        return .normal
    }

    private func assign(_ value: ScriptValue, to target: ScriptExpr, in scope: ScriptScope) throws {
        switch target.kind {
        case let .variable(name):
            guard scope.assign(name, value) else {
                throw ScriptError(line: target.line, kind: .runtime,
                                  message: undefinedMessage(for: name, in: scope, assigning: true))
            }

        case let .member(baseExpression, name):
            switch try evaluate(baseExpression, in: scope) {
            case let .map(map):
                map[name] = value
                try checkSize(map.count, line: target.line)
            case let .object(object):
                guard let resolver else {
                    throw ScriptError(line: target.line, kind: .runtime, message: L("“{}” cannot be changed here.", name))
                }
                try resolver.setMember(of: object, named: name, to: value, line: target.line)
            case .null:
                throw ScriptError(line: target.line, kind: .runtime,
                                  message: L("This is nil, so it has no “{}” to set.", name))
            case let other:
                throw ScriptError(line: target.line, kind: .runtime,
                                  message: L("A {} has no “{}” to set.", other.typeName, name))
            }

        case let .index(baseExpression, indexExpression):
            let base = try evaluate(baseExpression, in: scope)
            let index = try evaluate(indexExpression, in: scope)
            switch (base, index) {
            case let (.list(list), .number(position)):
                let offset = try listOffset(position, count: list.items.count, line: target.line)
                list.items[offset] = value
            case let (.map(map), .string(key)):
                map[key] = value
                try checkSize(map.count, line: target.line)
            default:
                throw ScriptError(line: target.line, kind: .runtime,
                                  message: L("A {} cannot be indexed with a {}.", base.typeName, index.typeName))
            }

        default:
            throw ScriptError(line: target.line, kind: .syntax, message: L("The left side of “=” has to be a name."))
        }
    }

    // MARK: Expressions

    private func evaluate(_ expression: ScriptExpr, in scope: ScriptScope) throws -> ScriptValue {
        try step(expression.line)
        let line = expression.line

        switch expression.kind {
        case let .number(value): return .number(value)
        case let .string(value): return .string(value)
        case let .bool(value): return .bool(value)
        case .null: return .null

        case let .list(items):
            try checkSize(items.count, line: line)
            return .list(ScriptList(try items.map { try evaluate($0, in: scope) }))

        case let .map(entries):
            let map = ScriptMap()
            for entry in entries {
                map[entry.key] = try evaluate(entry.value, in: scope)
            }
            try checkSize(map.count, line: line)
            return .map(map)

        case let .variable(name):
            guard let value = scope.lookup(name) else {
                throw ScriptError(line: line, kind: .runtime, message: undefinedMessage(for: name, in: scope, assigning: false))
            }
            return value

        case let .unary(op, operand):
            let value = try evaluate(operand, in: scope)
            switch op {
            case .not: return .bool(!value.isTruthy)
            case .negate:
                if let vector = ScriptVector(value) { return (vector * -1).value }
                return .number(-(try number(value, what: "-", line: line)))
            }

        case let .logical(isAnd, left, right):
            // Returns an operand, not just true or false, so the idiom
            // `name or "Guest"` gives a default.
            let first = try evaluate(left, in: scope)
            if isAnd { return first.isTruthy ? try evaluate(right, in: scope) : first }
            return first.isTruthy ? first : try evaluate(right, in: scope)

        case let .binary(op, left, right):
            return try binary(op, try evaluate(left, in: scope), try evaluate(right, in: scope), line: line)

        case let .call(calleeExpression, argumentExpressions):
            let callee = try evaluate(calleeExpression, in: scope)
            let arguments = try argumentExpressions.map { try evaluate($0, in: scope) }
            if case .null = callee, case let .variable(name) = calleeExpression.kind {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” is nil, not a function.", name))
            }
            return try call(callee, arguments, line: line)

        case let .member(baseExpression, name):
            let base = try evaluate(baseExpression, in: scope)
            return try member(of: base, named: name, line: line, baseExpression: baseExpression)

        case let .index(baseExpression, indexExpression):
            let base = try evaluate(baseExpression, in: scope)
            let index = try evaluate(indexExpression, in: scope)
            switch (base, index) {
            case let (.list(list), .number(position)):
                // Reading past the end gives nil rather than an error, so a
                // loop can test `if list[i] == nil`. Writing past the end is
                // an error — see `assign`.
                guard position == position.rounded(), position >= 1, Int(position) <= list.items.count else {
                    return .null
                }
                return list.items[Int(position) - 1]
            case let (.map(map), .string(key)):
                return map[key] ?? .null
            case let (.string(text), .number(position)):
                guard position == position.rounded(), position >= 1, Int(position) <= text.count else { return .null }
                return .string(String(text[text.index(text.startIndex, offsetBy: Int(position) - 1)]))
            default:
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("A {} cannot be indexed with a {}.", base.typeName, index.typeName))
            }

        case let .function(parameters, body):
            return .function(ScriptFunction(name: "func", parameters: parameters, body: body, closure: scope, line: line))
        }
    }

    private func member(of base: ScriptValue, named name: String, line: Int, baseExpression: ScriptExpr) throws -> ScriptValue {
        switch base {
        case let .map(map):
            return map[name] ?? .null
        case let .object(object):
            guard let resolver else { return .null }
            return try resolver.member(of: object, named: name, line: line)
        case let .list(list) where name == "length":
            return .number(Double(list.items.count))
        case let .string(text) where name == "length":
            return .number(Double(text.count))
        case .null:
            // The single most common runtime error, so it names the variable
            // that turned out to be nil.
            if case let .variable(variable) = baseExpression.kind {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” is nil, so it has no “{}”.", variable, name))
            }
            throw ScriptError(line: line, kind: .runtime, message: L("This is nil, so it has no “{}”.", name))
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A {} has no “{}”.", base.typeName, name))
        }
    }

    /// Calls a function value. Internal rather than private so the standard
    /// library's `sort`, `map` and `filter` can call back into the script —
    /// spending from the same budget, since they run inside a call already.
    func call(_ callee: ScriptValue, _ arguments: [ScriptValue], line: Int) throws -> ScriptValue {
        switch callee {
        case let .native(native):
            return try native.body(arguments, line)

        case let .function(function):
            callDepth += 1
            defer { callDepth -= 1 }
            guard callDepth <= limits.maximumCallDepth else {
                throw ScriptError(line: line, kind: .limit,
                                  message: L("Functions called each other too deeply. Does “{}” call itself forever?", function.name))
            }
            let scope = ScriptScope(parent: function.closure)
            for (index, name) in function.parameters.enumerated() {
                scope.declare(name, index < arguments.count ? arguments[index] : .null)
            }
            let flow = try execute(function.body, in: scope, isTopLevel: false)
            try checkFlowAtBoundary(flow, line: function.line)
            if case let .returned(value) = flow { return value }
            return .null

        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A {} cannot be called like a function.", callee.typeName))
        }
    }

    // MARK: Operators

    private func binary(_ op: BinaryOperator, _ left: ScriptValue, _ right: ScriptValue, line: Int) throws -> ScriptValue {
        switch op {
        case .equal: return .bool(left.isEqual(to: right))
        case .notEqual: return .bool(!left.isEqual(to: right))

        case .concatenate:
            return .string(try text(left.displayText + right.displayText, line: line))

        case .add:
            // `+` joins text when either side is text: "Score: " + score is
            // what everyone writes first, and refusing it teaches nothing.
            if case .string = left { return .string(try text(left.displayText + right.displayText, line: line)) }
            if case .string = right { return .string(try text(left.displayText + right.displayText, line: line)) }
            // Positions add like arrows: p.position + {x: 0, y: 5, z: 0}.
            if let a = ScriptVector(left), let b = ScriptVector(right) { return (a + b).value }
            return .number(try number(left, what: "+", line: line) + number(right, what: "+", line: line))

        case .subtract:
            if let a = ScriptVector(left), let b = ScriptVector(right) { return (a - b).value }
            return .number(try number(left, what: "-", line: line) - number(right, what: "-", line: line))
        case .multiply:
            if let a = ScriptVector(left), case let .number(n) = right { return (a * n).value }
            if case let .number(n) = left, let b = ScriptVector(right) { return (b * n).value }
            return .number(try number(left, what: "*", line: line) * number(right, what: "*", line: line))
        case .divide:
            if let a = ScriptVector(left), case let .number(n) = right {
                guard n != 0 else { throw ScriptError(line: line, kind: .runtime, message: L("Cannot divide by zero.")) }
                return (a * (1 / n)).value
            }
            let divisor = try number(right, what: "/", line: line)
            guard divisor != 0 else {
                throw ScriptError(line: line, kind: .runtime, message: L("Cannot divide by zero."))
            }
            return .number(try number(left, what: "/", line: line) / divisor)
        case .remainder:
            let divisor = try number(right, what: "%", line: line)
            guard divisor != 0 else {
                throw ScriptError(line: line, kind: .runtime, message: L("Cannot divide by zero."))
            }
            let dividend = try number(left, what: "%", line: line)
            // Floored, so `-1 % 4` is 3 — what wrapping an index needs.
            return .number(dividend - (dividend / divisor).rounded(.down) * divisor)

        case .less, .lessEqual, .greater, .greaterEqual:
            let ordering: Bool
            switch (left, right) {
            case let (.number(a), .number(b)):
                ordering = op == .less ? a < b : op == .lessEqual ? a <= b : op == .greater ? a > b : a >= b
            case let (.string(a), .string(b)):
                ordering = op == .less ? a < b : op == .lessEqual ? a <= b : op == .greater ? a > b : a >= b
            default:
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("Cannot compare a {} with a {}.", left.typeName, right.typeName))
            }
            return .bool(ordering)
        }
    }

    // MARK: Checks

    public func number(_ value: ScriptValue, what: String, line: Int) throws -> Double {
        if case let .number(number) = value { return number }
        throw ScriptError(line: line, kind: .runtime,
                          message: L("“{}” needs a number here, not {}.", what, value.typeName == "nil" ? "nil" : value.displayText))
    }

    private func text(_ value: String, line: Int) throws -> String {
        guard value.count <= limits.maximumTextLength else {
            throw ScriptError(line: line, kind: .limit, message: L("That text is too long."))
        }
        return value
    }

    public func checkSize(_ count: Int, line: Int) throws {
        guard count <= limits.maximumCollectionSize else {
            throw ScriptError(line: line, kind: .limit,
                              message: L("That list or map is too big (the limit is {}).", limits.maximumCollectionSize))
        }
    }

    private func listOffset(_ position: Double, count: Int, line: Int) throws -> Int {
        guard position == position.rounded(), position >= 1, Int(position) <= count else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("There is no item {} — the list has {}. Use append() to add one.",
                                         ScriptValue.format(position), count))
        }
        return Int(position) - 1
    }

    // MARK: Helpful errors

    private func undefinedMessage(for name: String, in scope: ScriptScope, assigning: Bool) -> String {
        if let suggestion = closestName(to: name, in: scope) {
            return L("“{}” is not defined. Did you mean “{}”?", name, suggestion)
        }
        if assigning {
            return L("“{}” is not defined. Use “let {} = …” to make it first.", name, name)
        }
        return L("“{}” is not defined.", name)
    }

    /// The nearest known name within two edits — enough to catch `scroe`
    /// for `score` and `palyers` for `players`, not so loose that it suggests
    /// something unrelated.
    private func closestName(to name: String, in scope: ScriptScope) -> String? {
        var candidates = builtinNames
        var current: ScriptScope? = scope
        while let each = current {
            candidates.formUnion(each.values.keys)
            current = each.parent
        }
        let wanted = name.lowercased()
        let ceiling = Swift.max(name.count, 2)
        var best: (name: String, distance: Int)?
        for candidate in candidates.sorted() {
            let distance: Int = ScriptInterpreter.editDistance(wanted, candidate.lowercased())
            guard distance <= 2, distance < ceiling else { continue }
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.name
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1,
                                       previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
