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
        unary("round") { $0.rounded() }
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

        // MARK: Text

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
        "floor", "ceil", "round", "abs", "sqrt", "sin", "cos", "min", "max", "clamp", "random",
        "len", "append", "remove", "contains", "keys", "join", "shuffle",
        "upper", "lower", "trim", "split"
    ]
}
