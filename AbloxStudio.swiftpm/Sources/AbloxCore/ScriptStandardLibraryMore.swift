import Foundation

// The standard library, the second round: the helpers creators kept writing
// for themselves. Smoothing, wrapping and snapping numbers; picking by
// weight; finding, counting and grouping in lists; maps read with a
// default; text padded, and numbers written the way games show them
// ("1,234", "1.5K", "1:05"); directions from yaws; colours from numbers.
//
// Each group is installed by its own function, so no one function body is
// long enough to slow the iPad's compiler down.
extension ScriptInterpreter {

    /// The names this file adds, in the order the reference lists them.
    static let moreStandardLibraryNames: [String] = [
        "int", "average", "median", "smoothstep", "inverse_lerp", "remap", "approach", "wrap", "snap",
        "angle_diff", "gcd", "chance", "random_float", "pick_weighted",
        "unique", "flatten", "zip", "first", "last", "find", "any", "all", "reduce", "count",
        "min_by", "max_by", "sort_by", "group_by", "chunk", "repeat",
        "values", "entries", "merge", "get",
        "pad_left", "pad_right", "capitalize", "words", "lines", "format", "comma", "short_number", "time_text",
        "direction", "forward", "yaw_to", "rotate_y", "angle_between",
        "rgb", "hsv", "mix_color", "random_color"
    ]

    func installMoreStandardLibrary() {
        installMoreMaths()
        installChoosing()
        installMoreLists()
        installListFunctions()
        installMaps()
        installMoreText()
        installNumbersAsText()
        installDirections()
        installColours()
    }

    // MARK: Helpers

    private func argument(_ arguments: [ScriptValue], _ index: Int) -> ScriptValue {
        index < arguments.count ? arguments[index] : .null
    }

    private func needs(_ arguments: [ScriptValue], _ count: Int, _ name: String, _ line: Int) throws {
        guard arguments.count >= count else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", name, count))
        }
    }

    private func listArgument(_ value: ScriptValue, _ name: String, _ line: Int) throws -> ScriptList {
        guard case let .list(list) = value else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a list first.", name))
        }
        return list
    }

    private func mapArgument(_ value: ScriptValue, _ name: String, _ line: Int) throws -> ScriptMap {
        guard case let .map(map) = value else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a map first.", name))
        }
        return map
    }

    private func numbers(in list: ScriptList, _ name: String, _ line: Int) throws -> [Double] {
        try list.items.map { try self.number($0, what: name, line: line) }
    }

    /// A position: {x, y, z}, or a player, NPC or block (their position).
    func place(_ value: ScriptValue, _ name: String, _ line: Int) throws -> ScriptVector {
        if let vector = ScriptVector(value) { return vector }
        if case let .object(object) = value, let resolver,
           let vector = ScriptVector(try resolver.member(of: object, named: "position", line: line)) {
            return vector
        }
        throw ScriptError(line: line, kind: .runtime,
                          message: L("That needs a player, a block or a position like {x: 0, y: 5, z: 0}, not {}.", value.typeName))
    }

    private func checkedText(_ result: String, _ line: Int) throws -> ScriptValue {
        guard result.count <= limits.maximumTextLength else {
            throw ScriptError(line: line, kind: .limit, message: L("That text is too long."))
        }
        return .string(result)
    }

    /// Orders two keys a sort or `min_by` compares: numbers, or text.
    private func comesBefore(_ a: ScriptValue, _ b: ScriptValue, _ line: Int) throws -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return x < y
        case let (.string(x), .string(y)): return x < y
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("Cannot compare a {} with a {}.", a.typeName, b.typeName))
        }
    }

    // MARK: Maths

    private func installMoreMaths() {
        /// The whole part, towards zero: `int(3.9)` is 3, `int(-3.9)` is -3.
        /// Numbers written as text work too, as with `num`.
        define("int") { arguments, _ in
            switch arguments.first ?? .null {
            case let .number(value): return .number(value.rounded(.towardZero))
            case let .string(text):
                guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return .null }
                return .number(value.rounded(.towardZero))
            case let .bool(value): return .number(value ? 1 : 0)
            default: return .null
            }
        }
        define("average") { [unowned self] arguments, line in
            let values = try self.numbers(in: try self.listArgument(self.argument(arguments, 0), "average", line), "average", line)
            guard !values.isEmpty else { return .null }
            return .number(values.reduce(0, +) / Double(values.count))
        }
        /// The middle value once sorted; the mean of the two middle ones
        /// for an even count.
        define("median") { [unowned self] arguments, line in
            let values = try self.numbers(in: try self.listArgument(self.argument(arguments, 0), "median", line), "median", line).sorted()
            guard !values.isEmpty else { return .null }
            let middle = values.count / 2
            return .number(values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2)
        }
        define("smoothstep") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "smoothstep", line)
            let a = try self.number(arguments[0], what: "smoothstep", line: line)
            let b = try self.number(arguments[1], what: "smoothstep", line: line)
            let t = try self.number(arguments[2], what: "smoothstep", line: line)
            guard a != b else { return .number(t < a ? 0 : 1) }
            let x = Swift.min(Swift.max((t - a) / (b - a), 0), 1)
            return .number(x * x * (3 - 2 * x))
        }
        define("inverse_lerp") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "inverse_lerp", line)
            let a = try self.number(arguments[0], what: "inverse_lerp", line: line)
            let b = try self.number(arguments[1], what: "inverse_lerp", line: line)
            let v = try self.number(arguments[2], what: "inverse_lerp", line: line)
            return .number(a == b ? 0 : (v - a) / (b - a))
        }
        /// `remap(v, 0, 100, 0, 1)`: where v is between the first two, as
        /// the same place between the last two.
        define("remap") { [unowned self] arguments, line in
            try self.needs(arguments, 5, "remap", line)
            let n = try arguments.prefix(5).map { try self.number($0, what: "remap", line: line) }
            let t = n[1] == n[2] ? 0 : (n[0] - n[1]) / (n[2] - n[1])
            return .number(n[3] + (n[4] - n[3]) * t)
        }
        /// Moves towards a target by at most `step`, never past it. Numbers
        /// or positions.
        define("approach") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "approach", line)
            let step = Swift.abs(try self.number(arguments[2], what: "approach", line: line))
            if case .number = arguments[0] {
                let current = try self.number(arguments[0], what: "approach", line: line)
                let target = try self.number(arguments[1], what: "approach", line: line)
                return .number(current < target ? Swift.min(current + step, target) : Swift.max(current - step, target))
            }
            let current = try self.place(arguments[0], "approach", line)
            let target = try self.place(arguments[1], "approach", line)
            let offset = target - current
            let length = offset.length
            guard length > step, length > 0 else { return target.value }
            return (current + offset * (step / length)).value
        }
        /// Keeps a number between low and high by going round, like a clock:
        /// `wrap(370, 0, 360)` is 10 and `wrap(-1, 0, 4)` is 3.
        define("wrap") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "wrap", line)
            let value = try self.number(arguments[0], what: "wrap", line: line)
            let low = try self.number(arguments[1], what: "wrap", line: line)
            let high = try self.number(arguments[2], what: "wrap", line: line)
            let span = high - low
            guard span != 0 else { return .number(low) }
            let offset = value - low
            return .number(low + offset - (offset / span).rounded(.down) * span)
        }
        /// To the nearest step: `snap(7.3, 2)` is 8. Positions snap each
        /// part, for building on a grid.
        define("snap") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "snap", line)
            let step = try self.number(arguments[1], what: "snap", line: line)
            func snapped(_ value: Double) -> Double { step > 0 ? (value / step).rounded() * step : value }
            if let vector = ScriptVector(arguments[0]) {
                return ScriptVector(snapped(vector.x), snapped(vector.y), snapped(vector.z)).value
            }
            return .number(snapped(try self.number(arguments[0], what: "snap", line: line)))
        }
        /// The shortest turn from one angle to another, -180 to 180:
        /// `angle_diff(350, 10)` is 20.
        define("angle_diff") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "angle_diff", line)
            let a = try self.number(arguments[0], what: "angle_diff", line: line)
            let b = try self.number(arguments[1], what: "angle_diff", line: line)
            return .number(ScriptInterpreter.shortestTurn(from: a, to: b))
        }
        define("gcd") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "gcd", line)
            var a = Swift.abs(try self.number(arguments[0], what: "gcd", line: line).rounded(.towardZero).scriptInt)
            var b = Swift.abs(try self.number(arguments[1], what: "gcd", line: line).rounded(.towardZero).scriptInt)
            while b != 0 { (a, b) = (b, a % b) }
            return .number(Double(a))
        }
    }

    /// -180 (exclusive) to 180: which way, and how far, to turn.
    static func shortestTurn(from a: Double, to b: Double) -> Double {
        let d = (b - a).truncatingRemainder(dividingBy: 360)
        guard d.isFinite else { return 0 }
        return d > 180 ? d - 360 : d <= -180 ? d + 360 : d
    }

    private func installChoosing() {
        /// True this many times in a hundred: `chance(25)`.
        define("chance") { [unowned self] arguments, line in
            let percent = try self.number(self.argument(arguments, 0), what: "chance", line: line)
            return .bool(self.random.unit() * 100 < percent)
        }
        define("random_float") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "random_float", line)
            let low = try self.number(arguments[0], what: "random_float", line: line)
            let high = try self.number(arguments[1], what: "random_float", line: line)
            return .number(low + (high - low) * self.random.unit())
        }
        /// Picks by weight. From a map, a name: `pick_weighted({common: 70,
        /// rare: 25, epic: 5})`. From a list of weights, a position.
        define("pick_weighted") { [unowned self] arguments, line in
            var choices: [(ScriptValue, Double)] = []
            switch self.argument(arguments, 0) {
            case let .map(map):
                for key in map.keys { choices.append((.string(key), try self.number(map[key] ?? .null, what: "pick_weighted", line: line))) }
            case let .list(list):
                for (index, item) in list.items.enumerated() {
                    choices.append((.number(Double(index + 1)), try self.number(item, what: "pick_weighted", line: line)))
                }
            default:
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a list first.", "pick_weighted"))
            }
            let weights = choices.map { $0.1.isFinite ? Swift.max($0.1, 0) : 0 }
            let total = weights.reduce(0, +)
            guard total > 0 else { return .null }
            var roll = self.random.unit() * total
            for (index, weight) in weights.enumerated() where weight > 0 {
                if roll < weight { return choices[index].0 }
                roll -= weight
            }
            // Rounding at the very top: the last choice that could be picked.
            return choices[weights.lastIndex { $0 > 0 } ?? 0].0
        }
    }

    // MARK: Lists

    /// A value as a key for spotting repeats: equal exactly when `==` says
    /// so in a script — by value for plain values, by identity otherwise.
    private enum SameKey: Hashable {
        case null, bool(Bool), number(Double), text(String), reference(ObjectIdentifier), object(String, String)

        init(_ value: ScriptValue) {
            switch value {
            case .null: self = .null
            case let .bool(value): self = .bool(value)
            case let .number(value): self = .number(value)
            case let .string(value): self = .text(value)
            case let .list(list): self = .reference(ObjectIdentifier(list))
            case let .map(map): self = .reference(ObjectIdentifier(map))
            case let .function(function): self = .reference(ObjectIdentifier(function))
            case let .native(native): self = .reference(ObjectIdentifier(native))
            case let .object(object): self = .object(object.kind, object.id)
            }
        }
    }

    private func installMoreLists() {
        /// Each item once, in the order first seen.
        define("unique") { [unowned self] arguments, line in
            let list = try self.listArgument(self.argument(arguments, 0), "unique", line)
            var seen: Set<SameKey> = []
            return .list(ScriptList(list.items.filter { seen.insert(SameKey($0)).inserted }))
        }
        /// Lists inside a list, opened out one level.
        define("flatten") { [unowned self] arguments, line in
            let list = try self.listArgument(self.argument(arguments, 0), "flatten", line)
            var items: [ScriptValue] = []
            for item in list.items {
                if case let .list(inner) = item { items.append(contentsOf: inner.items) } else { items.append(item) }
                try self.checkSize(items.count, line: line)
            }
            return .list(ScriptList(items))
        }
        /// Pairs: `zip(["a", "b"], [1, 2])` is [["a", 1], ["b", 2]].
        define("zip") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "zip", line)
            let a = try self.listArgument(arguments[0], "zip", line), b = try self.listArgument(arguments[1], "zip", line)
            return .list(ScriptList(zip(a.items, b.items).map { ScriptValue.list(ScriptList([$0, $1])) }))
        }
        define("first") { [unowned self] arguments, line in
            try self.listArgument(self.argument(arguments, 0), "first", line).items.first ?? .null
        }
        define("last") { [unowned self] arguments, line in
            try self.listArgument(self.argument(arguments, 0), "last", line).items.last ?? .null
        }
        /// Groups of a size: `chunk([1, 2, 3, 4, 5], 2)` is [[1, 2], [3, 4], [5]].
        define("chunk") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "chunk", line)
            let list = try self.listArgument(arguments[0], "chunk", line)
            let size = Swift.max(1, try self.number(arguments[1], what: "chunk", line: line).scriptInt)
            let groups = stride(from: 0, to: list.items.count, by: size).map { start in
                ScriptValue.list(ScriptList(Array(list.items[start..<Swift.min(start + size, list.items.count)])))
            }
            return .list(ScriptList(groups))
        }
        /// The same thing again: `repeat("ab", 3)` is "ababab";
        /// `repeat(0, 5)` is a list of five zeros.
        define("repeat") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "repeat", line)
            let times = Swift.max(0, try self.number(arguments[1], what: "repeat", line: line).scriptInt)
            if case let .string(text) = arguments[0] {
                guard text.isEmpty || times <= self.limits.maximumTextLength / text.count else {
                    throw ScriptError(line: line, kind: .limit, message: L("That text is too long."))
                }
                return .string(String(repeating: text, count: times))
            }
            try self.checkSize(times, line: line)
            return .list(ScriptList(Array(repeating: arguments[0], count: times)))
        }
    }

    private func installListFunctions() {
        /// The first item a function says yes to, or nil.
        define("find") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "find", line)
            for item in try self.listArgument(arguments[0], "find", line).items {
                if try self.call(arguments[1], [item], line: line).isTruthy { return item }
            }
            return .null
        }
        define("any") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "any", line)
            for item in try self.listArgument(arguments[0], "any", line).items {
                if try self.call(arguments[1], [item], line: line).isTruthy { return .bool(true) }
            }
            return .bool(false)
        }
        define("all") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "all", line)
            for item in try self.listArgument(arguments[0], "all", line).items {
                if !(try self.call(arguments[1], [item], line: line).isTruthy) { return .bool(false) }
            }
            return .bool(true)
        }
        /// Folds a list into one value: `reduce(list, func(total, x) return
        /// total + x end, 0)`.
        define("reduce") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "reduce", line)
            let items = try self.listArgument(arguments[0], "reduce", line).items
            var total = arguments.count > 2 ? arguments[2] : (items.first ?? .null)
            for item in items.dropFirst(arguments.count > 2 ? 0 : 1) {
                total = try self.call(arguments[1], [total, item], line: line)
            }
            return total
        }
        /// How many: of a value, of items a function says yes to, or of a
        /// piece of text inside some text.
        define("count") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "count", line)
            if case let .string(text) = arguments[0] {
                let part = arguments[1].displayText
                guard !part.isEmpty else { return .number(0) }
                return .number(Double(text.components(separatedBy: part).count - 1))
            }
            let items = try self.listArgument(arguments[0], "count", line).items
            switch arguments[1] {
            case .function, .native:
                return .number(Double(try items.filter { try self.call(arguments[1], [$0], line: line).isTruthy }.count))
            default:
                return .number(Double(items.filter { $0.isEqual(to: arguments[1]) }.count))
            }
        }
        /// The item whose function value is smallest: `min_by(players(),
        /// func(p) return distance(p, goal) end)`.
        define("min_by") { [unowned self] arguments, line in
            try self.extreme(arguments, "min_by", smallest: true, line)
        }
        define("max_by") { [unowned self] arguments, line in
            try self.extreme(arguments, "max_by", smallest: false, line)
        }
        /// A sorted copy, by what a function gives for each item:
        /// `sort_by(players(), func(p) return -p.score end)`.
        define("sort_by") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "sort_by", line)
            let items = try self.listArgument(arguments[0], "sort_by", line).items
            let keys = try items.map { try self.call(arguments[1], [$0], line: line) }
            // Positions sorted by their keys, so each key is worked out once.
            let order = try ScriptInterpreter.mergeSort(items.indices.map { ScriptValue.number(Double($0)) }) { a, b in
                guard case let .number(i) = a, case let .number(j) = b else { return false }
                return try self.comesBefore(keys[Int(i)], keys[Int(j)], line)
            }
            return .list(ScriptList(order.map { value in
                guard case let .number(i) = value else { return .null }
                return items[Int(i)]
            }))
        }
        /// A map of lists, by what a function gives for each item:
        /// `group_by(players(), func(p) return p.team end)`.
        define("group_by") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "group_by", line)
            let groups = ScriptMap()
            for item in try self.listArgument(arguments[0], "group_by", line).items {
                let key = try self.call(arguments[1], [item], line: line).displayText
                if case let .list(group) = groups[key] ?? .null {
                    group.items.append(item)
                } else {
                    groups[key] = .list(ScriptList([item]))
                    try self.checkSize(groups.count, line: line)
                }
            }
            return .map(groups)
        }
    }

    private func extreme(_ arguments: [ScriptValue], _ name: String, smallest: Bool, _ line: Int) throws -> ScriptValue {
        try needs(arguments, 2, name, line)
        var best: (item: ScriptValue, key: ScriptValue)?
        for item in try listArgument(arguments[0], name, line).items {
            let key = try call(arguments[1], [item], line: line)
            if let current = best {
                let better = try smallest ? comesBefore(key, current.key, line) : comesBefore(current.key, key, line)
                if better { best = (item, key) }
            } else {
                best = (item, key)
            }
        }
        return best?.item ?? .null
    }

    // MARK: Maps

    private func installMaps() {
        define("values") { [unowned self] arguments, line in
            let map = try self.mapArgument(self.argument(arguments, 0), "values", line)
            return .list(ScriptList(map.keys.map { map[$0] ?? .null }))
        }
        /// Each key with its value: [["gold", 5], ["gems", 2]].
        define("entries") { [unowned self] arguments, line in
            let map = try self.mapArgument(self.argument(arguments, 0), "entries", line)
            return .list(ScriptList(map.keys.map { ScriptValue.list(ScriptList([.string($0), map[$0] ?? .null])) }))
        }
        /// A new map with both; the second wins where both have a key.
        define("merge") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "merge", line)
            let merged = ScriptMap()
            for value in arguments.prefix(2) {
                let map = try self.mapArgument(value, "merge", line)
                for key in map.keys { merged[key] = map[key] }
            }
            try self.checkSize(merged.count, line: line)
            return .map(merged)
        }
        /// A value from a map, or a default when it is not there:
        /// `get(p.saved, "coins", 0)`. Works on nil too, for data that has
        /// not loaded yet.
        define("get") { [unowned self] arguments, _ in
            let fallback = self.argument(arguments, 2)
            let key = self.argument(arguments, 1)
            switch self.argument(arguments, 0) {
            case let .map(map):
                return map[key.displayText] ?? fallback
            case let .list(list):
                guard case let .number(position) = key, position == position.rounded(), position >= 1,
                      position <= Double(list.items.count) else { return fallback }
                return list.items[Int(position) - 1]
            default:
                return fallback
            }
        }
    }

    // MARK: Text

    private func installMoreText() {
        func pad(_ name: String, left: Bool) {
            define(name) { [unowned self] arguments, line in
                let text = self.argument(arguments, 0).displayText
                let width = Swift.min(try self.number(self.argument(arguments, 1), what: name, line: line).scriptInt,
                                      self.limits.maximumTextLength)
                let fill = arguments.count > 2 ? (arguments[2].displayText.first.map(String.init) ?? " ") : " "
                guard width > text.count else { return .string(text) }
                let padding = String(repeating: fill, count: width - text.count)
                return .string(left ? padding + text : text + padding)
            }
        }
        /// `pad_left(7, 3, "0")` is "007".
        pad("pad_left", left: true)
        pad("pad_right", left: false)

        define("capitalize") { [unowned self] arguments, _ in
            let text = self.argument(arguments, 0).displayText
            guard let first = text.first else { return .string("") }
            return .string(first.uppercased() + text.dropFirst())
        }
        define("words") { [unowned self] arguments, line in
            let parts = self.argument(arguments, 0).displayText
                .split(whereSeparator: { $0.isWhitespace }).map { ScriptValue.string(String($0)) }
            try self.checkSize(parts.count, line: line)
            return .list(ScriptList(parts))
        }
        define("lines") { [unowned self] arguments, line in
            let parts = self.argument(arguments, 0).displayText
                .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map { ScriptValue.string(String($0)) }
            try self.checkSize(parts.count, line: line)
            return .list(ScriptList(parts))
        }
        /// Fills each {} in order: `format("{} has {} coins", p.name, 5)`.
        define("format") { [unowned self] arguments, line in
            let template = self.argument(arguments, 0).displayText
            var result = ""
            var next = 1
            var rest = Substring(template)
            while let range = rest.range(of: "{}") {
                result += rest[..<range.lowerBound]
                result += next < arguments.count ? arguments[next].displayText : "{}"
                next += 1
                rest = rest[range.upperBound...]
                guard result.count <= self.limits.maximumTextLength else { break }
            }
            return try self.checkedText(result + rest, line)
        }
    }

    private func installNumbersAsText() {
        /// Thousands with commas: `comma(1234567)` is "1,234,567".
        define("comma") { [unowned self] arguments, line in
            .string(ScriptInterpreter.withCommas(try self.number(self.argument(arguments, 0), what: "comma", line: line)))
        }
        /// Big numbers short, the way idle games show them: 1.5K, 2.3M, 4B, 1T.
        define("short_number") { [unowned self] arguments, line in
            .string(ScriptInterpreter.shortNumber(try self.number(self.argument(arguments, 0), what: "short_number", line: line)))
        }
        /// Seconds as a clock: `time_text(65)` is "1:05"; an hour or more
        /// is "1:01:05".
        define("time_text") { [unowned self] arguments, line in
            .string(ScriptInterpreter.clockText(try self.number(self.argument(arguments, 0), what: "time_text", line: line)))
        }
    }

    static func withCommas(_ value: Double) -> String {
        let text = ScriptValue.format(value)
        guard value.isFinite else { return text }
        let negative = text.hasPrefix("-")
        let unsigned = negative ? String(text.dropFirst()) : text
        let parts = unsigned.split(separator: ".", maxSplits: 1)
        var whole = String(parts.first ?? "")
        var grouped = ""
        while whole.count > 3 {
            grouped = "," + whole.suffix(3) + grouped
            whole.removeLast(3)
        }
        grouped = whole + grouped
        return (negative ? "-" : "") + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }

    static func shortNumber(_ value: Double) -> String {
        guard value.isFinite else { return ScriptValue.format(value) }
        let units: [(size: Double, name: String)] = [(1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]
        func tenths(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        let size = Swift.abs(value)
        var index = units.lastIndex { size >= $0.size }
        // Rounding up to 1000 of one unit shows as one of the next: 999,960 is 1M.
        if let current = index {
            if current + 1 < units.count, tenths(size / units[current].size) >= 1000 { index = current + 1 }
        } else if tenths(size) >= 1000 {
            index = 0
        }
        guard let unit = index else { return ScriptValue.format(tenths(value)) }
        return ScriptValue.format(tenths(value / units[unit].size)) + units[unit].name
    }

    static func clockText(_ seconds: Double) -> String {
        let total = Swift.max(0, seconds.rounded(.down)).scriptInt
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
    }

    // MARK: Directions

    private func installDirections() {
        /// cos(90°) is 6e-17 in floating point; a direction reads 0 there,
        /// as a child would expect, and never "-0".
        func clean(_ value: Double) -> Double { Swift.abs(value) < 1e-9 ? 0 : value }

        /// Which way from one place to another, one metre long.
        define("direction") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "direction", line)
            let offset = try self.place(arguments[1], "direction", line) - self.place(arguments[0], "direction", line)
            let length = offset.length
            return (length > 0 ? offset * (1 / length) : offset).value
        }
        /// The way a yaw faces, flat and one metre long: `forward(p.yaw)`.
        define("forward") { [unowned self] arguments, line in
            let yaw = try self.number(self.argument(arguments, 0), what: "forward", line: line) * .pi / 180
            return ScriptVector(clean(Foundation.sin(yaw)), 0, clean(-Foundation.cos(yaw))).value
        }
        /// The yaw that faces from one place to another — for p.yaw or an
        /// NPC.
        define("yaw_to") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "yaw_to", line)
            let offset = try self.place(arguments[1], "yaw_to", line) - self.place(arguments[0], "yaw_to", line)
            guard offset.x * offset.x + offset.z * offset.z > 1e-12 else { return .number(0) }
            return .number(Foundation.atan2(offset.x, -offset.z) * 180 / .pi)
        }
        /// Turns a position or direction round the up axis; positive turns
        /// right, as yaw does.
        define("rotate_y") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "rotate_y", line)
            let v = try self.place(arguments[0], "rotate_y", line)
            let angle = try self.number(arguments[1], what: "rotate_y", line: line) * .pi / 180
            let c = Foundation.cos(angle), s = Foundation.sin(angle)
            return ScriptVector(clean(v.x * c - v.z * s), v.y, clean(v.x * s + v.z * c)).value
        }
        /// Degrees between two directions, 0 to 180.
        define("angle_between") { [unowned self] arguments, line in
            try self.needs(arguments, 2, "angle_between", line)
            let a = try self.place(arguments[0], "angle_between", line), b = try self.place(arguments[1], "angle_between", line)
            let lengths = a.length * b.length
            guard lengths > 0 else { return .number(0) }
            let cosine = Swift.min(Swift.max((a.x * b.x + a.y * b.y + a.z * b.z) / lengths, -1), 1)
            return .number(Foundation.acos(cosine) * 180 / .pi)
        }
    }

    // MARK: Colours

    private func installColours() {
        /// 0 to 255 each, and an optional see-through amount from 0 to 1:
        /// `rgb(255, 128, 0)` is "#FF8000".
        define("rgb") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "rgb", line)
            let parts = try arguments.prefix(3).map { Float(try self.number($0, what: "rgb", line: line) / 255) }
            let alpha = arguments.count > 3 ? Float(try self.number(arguments[3], what: "rgb", line: line)) : 1
            return .string(ColorRGBA(r: parts[0], g: parts[1], b: parts[2], a: alpha).hexString)
        }
        /// A colour from its hue (0 to 360, round the rainbow), how strong
        /// (0 to 1) and how bright (0 to 1): `hsv(120, 1, 1)` is green.
        define("hsv") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "hsv", line)
            let n = try arguments.prefix(3).map { try self.number($0, what: "hsv", line: line) }
            return .string(ScriptInterpreter.hsv(n[0], n[1], n[2]).hexString)
        }
        /// Part way from one colour to another: `mix_color("red", "blue", 0.5)`.
        define("mix_color") { [unowned self] arguments, line in
            try self.needs(arguments, 3, "mix_color", line)
            let colours = try arguments.prefix(2).map { value -> ColorRGBA in
                guard let colour = ScriptColor.parse(value.displayText) else {
                    throw ScriptError(line: line, kind: .runtime,
                                      message: L("“{}” is not a colour. Try “red”, “blue” or “#FF8800”.", value.displayText))
                }
                return colour
            }
            let t = Float(try self.number(arguments[2], what: "mix_color", line: line))
            return .string(ColorRGBA.lerp(colours[0], colours[1], t.isFinite ? t : 0).hexString)
        }
        /// A bright colour, any hue.
        define("random_color") { [unowned self] _, _ in
            .string(ScriptInterpreter.hsv(self.random.unit() * 360, 0.75, 1).hexString)
        }
    }

    static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> ColorRGBA {
        // Exact for any size of number, so h is always 0 to 6.
        let turn = hue.isFinite ? hue.truncatingRemainder(dividingBy: 360) : 0
        let h = (turn < 0 ? turn + 360 : turn) / 60
        let s = saturation.isFinite ? Swift.min(Swift.max(saturation, 0), 1) : 0
        let v = value.isFinite ? Swift.min(Swift.max(value, 0), 1) : 0
        let c = v * s
        let x = c * (1 - Swift.abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return ColorRGBA(r: Float(r + m), g: Float(g + m), b: Float(b + m))
    }
}
