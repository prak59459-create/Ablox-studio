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

public indirect enum ScriptExprKind: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    case list([ScriptExpr])
    /// `{ hp: 100, name: "Mika" }` — keys are always names, never expressions,
    /// which keeps a map literal readable and rules out a class of confusion.
    case map([(key: String, value: ScriptExpr)])
    case variable(String)
    case unary(UnaryOperator, ScriptExpr)
    case binary(BinaryOperator, ScriptExpr, ScriptExpr)
    /// `and` / `or`, which short-circuit and so cannot be ordinary binaries.
    case logical(isAnd: Bool, ScriptExpr, ScriptExpr)
    case call(ScriptExpr, [ScriptExpr])
    case member(ScriptExpr, String)
    case index(ScriptExpr, ScriptExpr)
    case function(parameters: [String], body: [ScriptStmt])

    public static func == (a: ScriptExprKind, b: ScriptExprKind) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        case let (.list(x), .list(y)): return x == y
        case let (.map(x), .map(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.variable(x), .variable(y)): return x == y
        case let (.unary(o1, e1), .unary(o2, e2)): return o1 == o2 && e1 == e2
        case let (.binary(o1, l1, r1), .binary(o2, l2, r2)): return o1 == o2 && l1 == l2 && r1 == r2
        case let (.logical(a1, l1, r1), .logical(a2, l2, r2)): return a1 == a2 && l1 == l2 && r1 == r2
        case let (.call(c1, a1), .call(c2, a2)): return c1 == c2 && a1 == a2
        case let (.member(e1, n1), .member(e2, n2)): return e1 == e2 && n1 == n2
        case let (.index(e1, i1), .index(e2, i2)): return e1 == e2 && i1 == i2
        case let (.function(p1, b1), .function(p2, b2)): return p1 == p2 && b1 == b2
        default: return false
        }
    }
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

    /// Event name → handler. One per event: a second `on tick` is an error at
    /// parse time rather than a silent replacement, because the second one
    /// winning is never what the author meant.
    public let handlers: [String: ScriptHandler]
}

public struct ScriptHandler: Equatable, Sendable {
    public let event: String
    public let parameters: [String]
    public let body: [ScriptStmt]
    public let line: Int
}
