import Foundation

/// An AbloxScript expression. Carries its line, so a runtime error can say
/// where it happened.
public struct ScriptExpr: Equatable, Sendable {
    public let kind: ScriptExprKind
    public let line: Int

    public init(_ kind: ScriptExprKind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

/// One `name: value` of a map literal. A struct rather than a pair so the
/// expression kinds get their `==` from the compiler: a `==` written by hand
/// would make every file that compares anything depend on this one
/// (AbloxCore/Comparisons.swift says why).
public struct ScriptMapEntry: Equatable, Sendable {
    public let key: String
    public let value: ScriptExpr

    public init(_ key: String, _ value: ScriptExpr) {
        self.key = key
        self.value = value
    }
}

public indirect enum ScriptExprKind: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    case list([ScriptExpr])
    /// `{ hp: 100, name: "Mika" }` — keys are always names, never expressions,
    /// which keeps a map literal readable and rules out a class of confusion.
    case map([ScriptMapEntry])
    case variable(String)
    case unary(UnaryOperator, ScriptExpr)
    case binary(BinaryOperator, ScriptExpr, ScriptExpr)
    /// `and` / `or`, which short-circuit and so cannot be ordinary binaries.
    case logical(isAnd: Bool, ScriptExpr, ScriptExpr)
    case call(ScriptExpr, [ScriptExpr])
    case member(ScriptExpr, String)
    case index(ScriptExpr, ScriptExpr)
    case function(parameters: [String], body: [ScriptStmt])
}

public enum UnaryOperator: String, Sendable {
    case negate = "-"
    case not
}

public enum BinaryOperator: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", remainder = "%"
    case concatenate = ".."
    case equal = "==", notEqual = "!=", less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
}

/// An AbloxScript statement.
public struct ScriptStmt: Equatable, Sendable {
    public let kind: ScriptStmtKind
    public let line: Int

    public init(_ kind: ScriptStmtKind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

public indirect enum ScriptStmtKind: Equatable, Sendable {
    /// `let name = value`. The value is optional: `let score` is nil.
    case declare(name: String, value: ScriptExpr?)
    /// `target = value`, where target is a variable, `a.b` or `a[i]`.
    case assign(target: ScriptExpr, value: ScriptExpr)
    case expression(ScriptExpr)
    case ifChain(branches: [ScriptBranch], otherwise: [ScriptStmt]?)
    case whileLoop(condition: ScriptExpr, body: [ScriptStmt])
    /// `for i in 1 to 10 step 2 do … end`, inclusive at both ends.
    case forRange(variable: String, from: ScriptExpr, to: ScriptExpr, step: ScriptExpr?, body: [ScriptStmt])
    /// `for p in players() do … end`
    case forEach(variable: String, sequence: ScriptExpr, body: [ScriptStmt])
    case function(name: String, parameters: [String], body: [ScriptStmt])
    /// `on tick(dt) … end` — a handler the game calls.
    case handler(event: String, parameters: [String], body: [ScriptStmt])
    case returnValue(ScriptExpr?)
    case breakLoop
    case continueLoop
}

public struct ScriptBranch: Equatable, Sendable {
    public let condition: ScriptExpr
    public let body: [ScriptStmt]
}

/// A parsed script: its top-level statements, with handlers pulled out.
public struct ScriptProgram: Equatable, Sendable {
    public let statements: [ScriptStmt]

    /// Event name → handlers, in file order. Within one file there is one
    /// per event — a second `on tick` in the same file is an error, because
    /// it is almost always a copy-paste — but separate `.absc` files may each
    /// have their own `on join`, and all of them run.
    public let handlers: [String: [ScriptHandler]]

    public init(statements: [ScriptStmt], handlers: [String: [ScriptHandler]]) {
        self.statements = statements
        self.handlers = handlers
    }

    /// Several files as one program: top levels in order, handlers merged.
    public static func combining(_ programs: [ScriptProgram]) -> ScriptProgram {
        var handlers: [String: [ScriptHandler]] = [:]
        for program in programs {
            for (event, list) in program.handlers {
                handlers[event, default: []].append(contentsOf: list)
            }
        }
        return ScriptProgram(statements: programs.flatMap(\.statements), handlers: handlers)
    }
}

public struct ScriptHandler: Equatable, Sendable {
    public let event: String
    public let parameters: [String]
    public let body: [ScriptStmt]
    public let line: Int
}
