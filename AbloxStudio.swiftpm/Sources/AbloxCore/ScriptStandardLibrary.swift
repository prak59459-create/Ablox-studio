import Foundation

/// The functions every script has, whatever game it is in.
///
/// Small on purpose. Each one here is a name a child has to learn and a name
/// Studio's reference has to explain; the test for adding one is whether a
/// game genuinely cannot be written without it.
extension ScriptInterpreter {

    func installStandardLibrary() {

        // MARK: Output

        define("print") { [unowned self] arguments, _ in
            self.log(arguments.map(\.displayText).joined(separator: " "))
            return .null
        }

        // MARK: Types and conversion

        define("type") { arguments, _ in
            .string((arguments.first ?? .null).typeName)
        }

        define("str") { arguments, _ in
            .string((arguments.first ?? .null).displayText)
        }

        /// `num("12")` is 12; `num("twelve")` is nil rather than an error, so
        /// a script can test what a player typed.
        define("num") { arguments, _ in
            switch arguments.first ?? .null {
            case let .number(value): return .number(value)
            case let .string(text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if let value = Double(trimmed), value.isFinite { return .number(value) }
                return .null
            case let .bool(value): return .number(value ? 1 : 0)
            default: return .null
            }
        }

        // MARK: Maths

        func unary(_ name: String, _ body: @escaping (Double) -> Double) {
            define(name) { [unowned self] arguments, line in
                .number(body(try self.number(arguments.first ?? .null, what: name, line: line)))
            }
        }
        unary("floor") { $0.rounded(.down) }
        unary("ceil") { $0.rounded(.up) }
        define("round") { [unowned self] arguments, line in
            let value = try self.number(arguments.first ?? .null, what: "round", line: line)
            guard arguments.count > 1 else { return .number(value.rounded()) }
            let digits = Swift.min(Swift.max(Int(try self.number(arguments[1], what: "round", line: line)), 0), 10)
            let scale = Foundation.pow(10, Double(digits))
            return .number((value * scale).rounded() / scale)
        }
        unary("abs") { Swift.abs($0) }
        unary("sqrt") { $0 < 0 ? .nan : $0.squareRoot() }
        unary("sin") { Foundation.sin($0 * .pi / 180) }   // degrees, like the rest of Ablox
        unary("cos") { Foundation.cos($0 * .pi / 180) }

        define("min") { [unowned self] arguments, line in
            guard !arguments.isEmpty else { return .null }
            return .number(try arguments.map { try self.number($0, what: "min", line: line) }.min()!)
        }
        define("max") { [unowned self] arguments, line in
            guard !arguments.isEmpty else { return .null }
            return .number(try arguments.map { try self.number($0, what: "max", line: line) }.max()!)
        }
        define("clamp") { [unowned self] arguments, line in
            guard arguments.count >= 3 else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "clamp", 3))
            }
            let value = try self.number(arguments[0], what: "clamp", line: line)
            let low = try self.number(arguments[1], what: "clamp", line: line)
            let high = try self.number(arguments[2], what: "clamp", line: line)
            return .number(Swift.min(Swift.max(value, low), high))
        }

        /// `random()` is in 0..1; `random(1, 6)` is a whole number, both ends
        /// included — a dice roll, which is how it will be used.
        define("random") { [unowned self] arguments, line in
            if arguments.count >= 2 {
                let low = Int(try self.number(arguments[0], what: "random", line: line).rounded())
                let high = Int(try self.number(arguments[1], what: "random", line: line).rounded())
                return .number(Double(self.random.integer(Swift.min(low, high), Swift.max(low, high))))
            }
            if case let .list(list) = arguments.first ?? .null {
                guard !list.items.isEmpty else { return .null }
                return list.items[self.random.integer(0, list.items.count - 1)]
            }
            return .number(self.random.unit())
        }

        // MARK: Lists

        define("len") { arguments, _ in
            switch arguments.first ?? .null {
            case let .list(list): return .number(Double(list.items.count))
            case let .map(map): return .number(Double(map.count))
            case let .string(text): return .number(Double(text.count))
            default: return .number(0)
            }
        }

        define("append") { [unowned self] arguments, line in
            guard case let .list(list) = arguments.first ?? .null else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a list first.", "append"))
            }
            list.items.append(arguments.count > 1 ? arguments[1] : .null)
            try self.checkSize(list.items.count, line: line)
            return .list(list)
        }

        define("remove") { [unowned self] arguments, line in
            guard case let .list(list) = arguments.first ?? .null else {
                if case let .map(map) = arguments.first ?? .null, arguments.count > 1, case let .string(key) = arguments[1] {
                    let old = map[key] ?? .null
                    map[key] = nil
                    return old
                }
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a list first.", "remove"))
            }
            guard !list.items.isEmpty else { return .null }
            // Without a position, the last item — the one `append` added.
            let position = arguments.count > 1 ? Int(try self.number(arguments[1], what: "remove", line: line)) : list.items.count
            guard position >= 1, position <= list.items.count else { return .null }
            return list.items.remove(at: position - 1)
        }

        define("contains") { arguments, _ in
            guard arguments.count >= 2 else { return .bool(false) }
            switch arguments[0] {
            case let .list(list): return .bool(list.items.contains { $0.isEqual(to: arguments[1]) })
            case let .map(map): return .bool(map[arguments[1].displayText] != nil)
            case let .string(text): return .bool(text.contains(arguments[1].displayText))
            default: return .bool(false)
            }
        }

        define("keys") { arguments, _ in
            guard case let .map(map) = arguments.first ?? .null else { return .list(ScriptList()) }
            return .list(ScriptList(map.keys.map { .string($0) }))
        }

        define("join") { [unowned self] arguments, line in
            guard case let .list(list) = arguments.first ?? .null else { return .string("") }
            let separator = arguments.count > 1 ? arguments[1].displayText : ", "
            let joined = list.items.map(\.displayText).joined(separator: separator)
            guard joined.count <= self.limits.maximumTextLength else {
                throw ScriptError(line: line, kind: .limit, message: L("That text is too long."))
            }
            return .string(joined)
        }

        /// Shuffles in place with the world's seeded randomness, so a test (or
        /// a replay) gets the same order every time.
        define("shuffle") { [unowned self] arguments, _ in
            guard case let .list(list) = arguments.first ?? .null else { return .null }
            guard list.items.count > 1 else { return .list(list) }
            for index in stride(from: list.items.count - 1, to: 0, by: -1) {
                let other = self.random.integer(0, index)
                list.items.swapAt(index, other)
            }
            return .list(list)
        }

        // MARK: More maths

        unary("tan") { Foundation.tan($0 * .pi / 180) }
        unary("asin") { Foundation.asin($0) * 180 / .pi }
        unary("acos") { Foundation.acos($0) * 180 / .pi }
        unary("atan") { Foundation.atan($0) * 180 / .pi }
        unary("log") { $0 <= 0 ? .nan : Foundation.log($0) }
        unary("exp") { Foundation.exp(Swift.min($0, 700)) }
        unary("sign") { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
        defineValue("pi", .number(.pi))

        define("pow") { [unowned self] arguments, line in
            guard arguments.count >= 2 else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "pow", 2))
            }
            let result = Foundation.pow(try self.number(arguments[0], what: "pow", line: line),
                                        try self.number(arguments[1], what: "pow", line: line))
            return .number(result.isFinite ? result : 0)
        }
        /// The angle, in degrees, of the direction (x, z) — which way to face
        /// to look along it.
        define("atan2") { [unowned self] arguments, line in
            guard arguments.count >= 2 else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "atan2", 2))
            }
            return .number(Foundation.atan2(try self.number(arguments[0], what: "atan2", line: line),
                                            try self.number(arguments[1], what: "atan2", line: line)) * 180 / .pi)
        }
        define("lerp") { [unowned self] arguments, line in
            guard arguments.count >= 3 else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "lerp", 3))
            }
            let t = try self.number(arguments[2], what: "lerp", line: line)
            if let a = ScriptVector(arguments[0]), let b = ScriptVector(arguments[1]) {
                return (a + (b - a) * t).value
            }
            let a = try self.number(arguments[0], what: "lerp", line: line)
            let b = try self.number(arguments[1], what: "lerp", line: line)
            return .number(a + (b - a) * t)
        }

        // MARK: Vectors

        define("vec") { [unowned self] arguments, line in
            ScriptVector(try self.number(arguments.count > 0 ? arguments[0] : .number(0), what: "vec", line: line),
                         try self.number(arguments.count > 1 ? arguments[1] : .number(0), what: "vec", line: line),
                         try self.number(arguments.count > 2 ? arguments[2] : .number(0), what: "vec", line: line)).value
        }
        func vector(_ value: ScriptValue, _ what: String, _ line: Int) throws -> ScriptVector {
            guard let vector = ScriptVector(value) else {
                throw ScriptError(line: line, kind: .runtime, message: L("That needs {x, y, z}, not {}.", value.typeName))
            }
            return vector
        }
        define("magnitude") { arguments, line in
            .number(try vector(arguments.first ?? .null, "magnitude", line).length)
        }
        define("normalize") { arguments, line in
            let v = try vector(arguments.first ?? .null, "normalize", line)
            let length = v.length
            return (length > 0 ? v * (1 / length) : v).value
        }
        define("dot") { arguments, line in
            guard arguments.count >= 2 else { return .number(0) }
            let a = try vector(arguments[0], "dot", line), b = try vector(arguments[1], "dot", line)
            return .number(a.x * b.x + a.y * b.y + a.z * b.z)
        }
        define("cross") { arguments, line in
            guard arguments.count >= 2 else { return .null }
            let a = try vector(arguments[0], "cross", line), b = try vector(arguments[1], "cross", line)
            return ScriptVector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x).value
        }

        // MARK: More lists

        define("range") { [unowned self] arguments, line in
            let from = try self.number(arguments.first ?? .null, what: "range", line: line)
            let to = arguments.count > 1 ? try self.number(arguments[1], what: "range", line: line) : from
            let start = arguments.count > 1 ? from : 1
            let step: Double = start <= to ? 1 : -1
            let count = Int((Swift.abs(to - start)).rounded(.down)) + 1
            try self.checkSize(count, line: line)
            return .list(ScriptList((0..<count).map { .number(start + Double($0) * step) }))
        }
        define("insert") { [unowned self] arguments, line in
            guard arguments.count >= 3, case let .list(list) = arguments[0] else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a list first.", "insert"))
            }
            let position = Int(try self.number(arguments[1], what: "insert", line: line))
            list.items.insert(arguments[2], at: Swift.min(Swift.max(position - 1, 0), list.items.count))
            try self.checkSize(list.items.count, line: line)
            return .list(list)
        }
        define("index_of") { arguments, _ in
            guard arguments.count >= 2 else { return .null }
            switch arguments[0] {
            case let .list(list):
                return list.items.firstIndex { $0.isEqual(to: arguments[1]) }.map { .number(Double($0 + 1)) } ?? .null
            case let .string(text):
                guard let range = text.range(of: arguments[1].displayText) else { return .null }
                return .number(Double(text.distance(from: text.startIndex, to: range.lowerBound) + 1))
            default:
                return .null
            }
        }
        define("slice") { [unowned self] arguments, line in
            let from = Int(try self.number(arguments.count > 1 ? arguments[1] : .number(1), what: "slice", line: line))
            switch arguments.first ?? .null {
            case let .list(list):
                let to = arguments.count > 2 ? Int(try self.number(arguments[2], what: "slice", line: line)) : list.items.count
                let low = Swift.max(from, 1), high = Swift.min(to, list.items.count)
                return .list(ScriptList(low <= high ? Array(list.items[(low - 1)..<high]) : []))
            case let .string(text):
                let characters = Array(text)
                let to = arguments.count > 2 ? Int(try self.number(arguments[2], what: "slice", line: line)) : characters.count
                let low = Swift.max(from, 1), high = Swift.min(to, characters.count)
                return .string(low <= high ? String(characters[(low - 1)..<high]) : "")
            default:
                return .null
            }
        }
        define("reverse") { arguments, _ in
            switch arguments.first ?? .null {
            case let .list(list): return .list(ScriptList(list.items.reversed()))
            case let .string(text): return .string(String(text.reversed()))
            default: return .null
            }
        }
        define("copy") { arguments, _ in
            switch arguments.first ?? .null {
            case let .list(list): return .list(ScriptList(list.items))
            case let .map(map):
                let copy = ScriptMap()
                for key in map.keys { copy[key] = map[key] }
                return .map(copy)
            case let other: return other
            }
        }
        define("sum") { [unowned self] arguments, line in
            guard case let .list(list) = arguments.first ?? .null else { return .number(0) }
            return .number(try list.items.reduce(0) { $0 + (try self.number($1, what: "sum", line: line)) })
        }
        /// Sorted copy: numbers and text in order, or by a function that
        /// says whether `a` comes before `b`.
        define("sort") { [unowned self] arguments, line in
            guard case let .list(list) = arguments.first ?? .null else { return .null }
            let before: (ScriptValue, ScriptValue) throws -> Bool
            if arguments.count > 1 {
                let comparator = arguments[1]
                before = { a, b in try self.call(comparator, [a, b], line: line).isTruthy }
            } else {
                before = { a, b in
                    switch (a, b) {
                    case let (.number(x), .number(y)): return x < y
                    case let (.string(x), .string(y)): return x < y
                    default:
                        throw ScriptError(line: line, kind: .runtime,
                                          message: L("Cannot compare a {} with a {}.", a.typeName, b.typeName))
                    }
                }
            }
            return .list(ScriptList(try ScriptInterpreter.mergeSort(list.items, by: before)))
        }
        define("map") { [unowned self] arguments, line in
            guard arguments.count >= 2, case let .list(list) = arguments[0] else { return .null }
            return .list(ScriptList(try list.items.map { try self.call(arguments[1], [$0], line: line) }))
        }
        define("filter") { [unowned self] arguments, line in
            guard arguments.count >= 2, case let .list(list) = arguments[0] else { return .null }
            return .list(ScriptList(try list.items.filter { try self.call(arguments[1], [$0], line: line).isTruthy }))
        }

        // MARK: Text

        define("replace") { [unowned self] arguments, line in
            guard arguments.count >= 3 else { return arguments.first ?? .null }
            let result = arguments[0].displayText.replacingOccurrences(of: arguments[1].displayText, with: arguments[2].displayText)
            guard result.count <= self.limits.maximumTextLength else {
                throw ScriptError(line: line, kind: .limit, message: L("That text is too long."))
            }
            return .string(result)
        }
        define("starts_with") { arguments, _ in
            guard arguments.count >= 2 else { return .bool(false) }
            return .bool(arguments[0].displayText.hasPrefix(arguments[1].displayText))
        }
        define("ends_with") { arguments, _ in
            guard arguments.count >= 2 else { return .bool(false) }
            return .bool(arguments[0].displayText.hasSuffix(arguments[1].displayText))
        }
        /// A number with a fixed count of decimals: `fixed(3.14159, 2)` is "3.14".
        define("fixed") { [unowned self] arguments, line in
            let value = try self.number(arguments.first ?? .null, what: "fixed", line: line)
            let digits = arguments.count > 1 ? Int(try self.number(arguments[1], what: "fixed", line: line)) : 0
            return .string(String(format: "%.\(Swift.min(Swift.max(digits, 0), 10))f", value))
        }

        define("upper") { arguments, _ in .string((arguments.first ?? .null).displayText.uppercased()) }
        define("lower") { arguments, _ in .string((arguments.first ?? .null).displayText.lowercased()) }
        define("trim") { arguments, _ in
            .string((arguments.first ?? .null).displayText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        define("split") { [unowned self] arguments, line in
            let text = (arguments.first ?? .null).displayText
            let separator = arguments.count > 1 ? arguments[1].displayText : " "
            let parts = separator.isEmpty
                ? text.map { ScriptValue.string(String($0)) }
                : text.components(separatedBy: separator).map { ScriptValue.string($0) }
            try self.checkSize(parts.count, line: line)
            return .list(ScriptList(parts))
        }
    }

    /// Every name the standard library defines, for Studio's reference and
    /// for tests that keep the two in step.
    public static let standardLibraryNames: [String] = [
        "print", "type", "str", "num",
        "floor", "ceil", "round", "abs", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "pow", "log", "exp", "sign", "lerp", "pi", "min", "max", "clamp", "random",
        "vec", "magnitude", "normalize", "dot", "cross",
        "len", "append", "remove", "insert", "contains", "index_of", "keys", "join", "shuffle",
        "range", "slice", "reverse", "copy", "sum", "sort", "map", "filter",
        "upper", "lower", "trim", "split", "replace", "starts_with", "ends_with", "fixed"
    ]

    /// A stable sort that lets the comparison throw — a script comparator
    /// can fail, or run out of budget, and that must surface as its error.
    static func mergeSort(_ items: [ScriptValue], by before: (ScriptValue, ScriptValue) throws -> Bool) throws -> [ScriptValue] {
        guard items.count > 1 else { return items }
        let middle = items.count / 2
        let left = try mergeSort(Array(items[..<middle]), by: before)
        let right = try mergeSort(Array(items[middle...]), by: before)
        var merged: [ScriptValue] = []
        merged.reserveCapacity(items.count)
        var i = 0, j = 0
        while i < left.count, j < right.count {
            if try before(right[j], left[i]) {
                merged.append(right[j]); j += 1
            } else {
                merged.append(left[i]); i += 1
            }
        }
        merged.append(contentsOf: left[i...])
        merged.append(contentsOf: right[j...])
        return merged
    }
}
