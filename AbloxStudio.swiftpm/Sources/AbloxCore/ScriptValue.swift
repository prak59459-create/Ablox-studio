import Foundation

/// A value in a running AbloxScript program.
///
/// Lists and maps are references, as they are in nearly every scripting
/// language a child will meet next: passing a list to a function and adding to
/// it changes the caller's list. Numbers are always `Double`, so `7 / 2` is
/// `3.5` rather than a surprise.
public enum ScriptValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list(ScriptList)
    case map(ScriptMap)
    case function(ScriptFunction)
    case native(ScriptNative)
    /// A player, block or anything else the game hands to a script. Its
    /// members are answered by the runtime, not stored here.
    case object(ScriptObject)

    /// `nil` and `false` are false; everything else — including 0 and "" —
    /// is true. The Lua rule, and the only one that needs no exceptions.
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case let .bool(value): return value
        default: return true
        }
    }

    /// The name a script sees from `type(x)`, and the one error messages use.
    public var typeName: String {
        switch self {
        case .null: return "nil"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "text"
        case .list: return "list"
        case .map: return "map"
        case .function, .native: return "function"
        case let .object(object): return object.kind
        }
    }

    /// How the value prints: `3` not `3.0`, `[1, 2]`, `{hp: 10}`.
    public var displayText: String {
        displayText(depth: 0)
    }

    private func displayText(depth: Int) -> String {
        // A list that contains itself would otherwise print forever.
        guard depth < 6 else { return "…" }
        switch self {
        case .null: return "nil"
        case let .bool(value): return value ? "true" : "false"
        case let .number(value): return ScriptValue.format(value)
        case let .string(value): return value
        case let .list(list):
            return "[" + list.items.map { $0.quotedText(depth: depth + 1) }.joined(separator: ", ") + "]"
        case let .map(map):
            return "{" + map.keys.map { "\($0): \(map.values[$0]?.quotedText(depth: depth + 1) ?? "nil")" }
                .joined(separator: ", ") + "}"
        case let .function(function): return "func \(function.name)"
        case let .native(native): return "func \(native.name)"
        case let .object(object): return object.displayName
        }
    }

    private func quotedText(depth: Int) -> String {
        if case let .string(value) = self { return "\"\(value)\"" }
        return displayText(depth: depth)
    }

    /// Whole numbers without a decimal point; others to at most four places.
    public static func format(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Equality as a script sees it: by value for plain values, by identity
    /// for lists, maps and functions, by id for game objects.
    public func isEqual(to other: ScriptValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.list(a), .list(b)): return a === b
        case let (.map(a), .map(b)): return a === b
        case let (.function(a), .function(b)): return a === b
        case let (.native(a), .native(b)): return a === b
        case let (.object(a), .object(b)): return a.kind == b.kind && a.id == b.id
        default: return false
        }
    }
}

// MARK: - Reference types

public final class ScriptList {
    public var items: [ScriptValue]
    public init(_ items: [ScriptValue] = []) { self.items = items }
}

public final class ScriptMap {
    /// Insertion order is kept, so a map prints and iterates the way it was
    /// written — a dictionary's order would change between runs.
    public private(set) var keys: [String] = []
    public private(set) var values: [String: ScriptValue] = [:]

    public init() {}

    public var count: Int { keys.count }

    public subscript(key: String) -> ScriptValue? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
}

/// A function written in AbloxScript, with the scope it was defined in.
public final class ScriptFunction {
    public let name: String
    public let parameters: [String]
    public let body: [ScriptStmt]
    public let closure: ScriptScope
    public let line: Int

    public init(name: String, parameters: [String], body: [ScriptStmt], closure: ScriptScope, line: Int) {
        self.name = name
        self.parameters = parameters
        self.body = body
        self.closure = closure
        self.line = line
    }
}

/// A function provided by the game or the standard library.
public final class ScriptNative {
    public let name: String
    public let body: ([ScriptValue], Int) throws -> ScriptValue

    /// - Parameter body: receives the arguments and the calling line, so an
    ///   error it throws can point at the script rather than at Swift.
    public init(_ name: String, _ body: @escaping ([ScriptValue], Int) throws -> ScriptValue) {
        self.name = name
        self.body = body
    }
}

/// Something the game owns — a player, a block — seen from a script.
public final class ScriptObject {
    public let kind: String
    public let id: String
    public let displayName: String

    public init(kind: String, id: String, displayName: String) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }
}

/// Variables, nested by block.
public final class ScriptScope {
    public private(set) var values: [String: ScriptValue] = [:]
    public let parent: ScriptScope?

    public init(parent: ScriptScope?) {
        self.parent = parent
    }

    public func declare(_ name: String, _ value: ScriptValue) {
        values[name] = value
    }

    public func lookup(_ name: String) -> ScriptValue? {
        var scope: ScriptScope? = self
        while let current = scope {
            if let value = current.values[name] { return value }
            scope = current.parent
        }
        return nil
    }

    /// Assigns to the nearest scope that declared `name`.
    ///
    /// Returns false when nothing did. Assigning to an undeclared name is an
    /// error rather than an implicit global, because the usual cause is a
    /// typo — `scroe = scroe + 1` — and a silently created second variable is
    /// the hardest kind of bug for a beginner to find.
    public func assign(_ name: String, _ value: ScriptValue) -> Bool {
        var scope: ScriptScope? = self
        while let current = scope {
            if current.values[name] != nil {
                current.values[name] = value
                return true
            }
            scope = current.parent
        }
        return false
    }
}

// MARK: - Randomness

/// SplitMix64. Seeded, so a world's randomness can be replayed in a test and
/// is the same whether the host is a new iPad or an old one.
public struct ScriptRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In `0 ..< 1`.
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// A whole number in `low ... high`, inclusive, as a dice roll would be.
    public mutating func integer(_ low: Int, _ high: Int) -> Int {
        guard high > low else { return low }
        let span = UInt64(high - low + 1)
        return low + Int(next() % span)
    }
}
