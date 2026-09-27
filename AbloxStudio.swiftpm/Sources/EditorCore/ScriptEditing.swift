import Foundation

// Help with writing `.absc`: suggestions while typing, the list of handlers
// and functions, tidy indentation, searching every file, what changed, ready
// snippets, and programming with blocks instead of typing.

// MARK: - Suggestions while typing

public enum ScriptCompletion {

    public struct Suggestion: Hashable, Sendable, Identifiable {
        public var text: String
        public var detail: String
        public var id: String { text }
    }

    /// What is being typed just before `cursor` (a UTF-16 offset): the
    /// start of a word, what it follows (`p` in `p.hea`), and where it is.
    public struct Context: Hashable, Sendable {
        public var prefix: String
        public var receiver: String?
        /// Inside `block("…` or `blocks("…`: a part's name or tag.
        public var inBlockName: Bool
        public var range: NSRange
    }

    public static func context(in text: String, cursor: Int) -> Context {
        let ns = text as NSString
        let end = Swift.max(0, Swift.min(cursor, ns.length))
        var start = end
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        let lineStart = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end)).location
        let before = ns.substring(with: NSRange(location: lineStart == NSNotFound ? 0 : lineStart + 1,
                                                length: end - (lineStart == NSNotFound ? 0 : lineStart + 1)))
        // `block("Gre` → part names.
        if let match = before.range(of: #"blocks?\(\s*"([^"]*)$"#, options: .regularExpression) {
            let typed = String(before[match]).split(separator: "\"", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let length = (typed as NSString).length
            return Context(prefix: typed, receiver: nil, inBlockName: true, range: NSRange(location: end - length, length: length))
        }
        while start > 0, isWord(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: end - start))
        var receiver: String?
        if start > 0, ns.character(at: start - 1) == 46 {   // "."
            var receiverStart = start - 1
            while receiverStart > 0, isWord(ns.character(at: receiverStart - 1)) { receiverStart -= 1 }
            let name = ns.substring(with: NSRange(location: receiverStart, length: start - 1 - receiverStart))
            if !name.isEmpty { receiver = name }
        }
        return Context(prefix: prefix, receiver: receiver, inBlockName: false, range: NSRange(location: start, length: end - start))
    }

    static let gameMembers = ["respawn_time", "friendly_fire", "time", "round_over"]

    /// Up to `limit` things that could come next, best first.
    public static func suggestions(for context: Context, source: String, blockNames: [String], limit: Int = 12) -> [Suggestion] {
        var candidates: [Suggestion] = []
        if context.inBlockName {
            candidates = blockNames.map { Suggestion(text: $0, detail: L("part")) }
        } else if let receiver = context.receiver {
            let lower = receiver.lowercased()
            if lower == "world" {
                candidates = GameRuntime.worldMemberNames.map { Suggestion(text: $0, detail: "world") }
            } else if lower == "game" {
                candidates = gameMembers.map { Suggestion(text: $0, detail: "game") }
            } else if lower == "b" || lower.hasSuffix("block") || lower == "part" {
                candidates = GameRuntime.blockMemberNames.map { Suggestion(text: $0, detail: L("part")) }
            } else {
                candidates = (GameRuntime.characterMemberNames + GameRuntime.playerOnlyMemberNames + GameRuntime.npcOnlyMemberNames)
                    .map { Suggestion(text: $0, detail: L("player")) }
                    + GameRuntime.blockMemberNames.map { Suggestion(text: $0, detail: L("part")) }
            }
        } else {
            guard !context.prefix.isEmpty else { return [] }
            let beforeWord = source as NSString
            let lineStart = beforeWord.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: context.range.location)).location
            let lead = beforeWord.substring(with: NSRange(location: lineStart == NSNotFound ? 0 : lineStart + 1,
                                                          length: context.range.location - (lineStart == NSNotFound ? 0 : lineStart + 1)))
            if lead.trimmingCharacters(in: .whitespaces) == "on" {
                candidates = GameRuntime.Event.allCases.map { Suggestion(text: $0.rawValue, detail: L("event")) }
            } else {
                candidates = ScriptHighlighter.keywords.sorted().map { Suggestion(text: $0, detail: L("word")) }
                    + GameRuntime.gameAPINames.map { Suggestion(text: $0, detail: L("game")) }
                    + ScriptInterpreter.standardLibraryNames.map { Suggestion(text: $0, detail: L("library")) }
                    + declaredNames(in: source).map { Suggestion(text: $0, detail: L("yours")) }
            }
        }
        let prefix = context.prefix.lowercased()
        var seen: Set<String> = []
        let matching = candidates.filter { suggestion in
            let name = suggestion.text.lowercased()
            guard name != prefix, name.hasPrefix(prefix) || (prefix.count >= 2 && name.contains(prefix)) else { return false }
            return seen.insert(suggestion.text).inserted
        }
        return Array(matching.sorted { a, b in
            let aStarts = a.text.lowercased().hasPrefix(prefix), bStarts = b.text.lowercased().hasPrefix(prefix)
            if aStarts != bStarts { return aStarts }
            return a.text.count != b.text.count ? a.text.count < b.text.count : a.text < b.text
        }.prefix(limit))
    }

    /// Variables and functions the script makes.
    static func declaredNames(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\b(?:let|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let ns = source as NSString
        return Array(Set(pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })).sorted()
    }
}

// MARK: - Outline

public struct ScriptOutlineItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case event, function, variable }
    public var kind: Kind
    public var name: String
    public var line: Int
    public var id: String { "\(line):\(name)" }
}

public enum ScriptOutline {
    /// The handlers, functions and top-level variables, in order.
    public static func items(in source: String) -> [ScriptOutlineItem] {
        var items: [ScriptOutlineItem] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("on "), let name = word(after: "on ", in: trimmed) {
                let parameters = trimmed.drop { $0 != "(" }
                items.append(ScriptOutlineItem(kind: .event, name: "on " + name + String(parameters.prefix { $0 != ")" }) + ")", line: index + 1))
            } else if trimmed.hasPrefix("func "), let name = word(after: "func ", in: trimmed) {
                items.append(ScriptOutlineItem(kind: .function, name: name + "()", line: index + 1))
            } else if line.hasPrefix("let "), let name = word(after: "let ", in: line) {
                items.append(ScriptOutlineItem(kind: .variable, name: name, line: index + 1))
            }
        }
        return items
    }

    private static func word(after lead: String, in line: String) -> String? {
        let rest = line.dropFirst(lead.count)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

// MARK: - Tidy indentation

public enum ScriptFormatter {
    /// Re-indents with two spaces a level and trims the ends of lines.
    /// Nothing else changes, so it is always safe to run.
    public static func format(_ source: String, indent: String = "  ") -> String {
        var level = 0
        var output: [String] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                output.append("")
                continue
            }
            let code = words(ofCode: trimmed)
            let first = code.first ?? ""
            let dedents = ["end", "else", "elif"].contains(first)
            output.append(String(repeating: indent, count: Swift.max(0, level - (dedents ? 1 : 0))) + trimmed)
            var change = 0
            for (index, word) in code.enumerated() {
                switch word {
                case "then", "do", "func": change += 1
                case "end": change -= 1
                case "on" where index == 0: change += 1
                case "elif" where index == 0: change -= 1
                default: break
                }
            }
            level = Swift.max(0, level + change)
        }
        return output.joined(separator: "\n")
    }

    /// The words of a line, leaving out strings and the comment.
    static func words(ofCode line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        var previous: Character = " "
        for character in line {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                previous = character
                continue
            }
            if character == "-", previous == "-" {
                current = ""
                break
            }
            if character == "\"" {
                inString = true
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

// MARK: - Search every file

public struct ScriptMatch: Hashable, Sendable, Identifiable {
    public var fileID: UUID
    public var fileName: String
    public var line: Int
    public var column: Int
    public var preview: String
    public var id: String { "\(fileID)|\(line)|\(column)" }
}

public enum ScriptSearch {
    public static func find(_ query: String, in files: [ScriptFile], caseSensitive: Bool = false) -> [ScriptMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [ScriptMatch] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for file in files {
            for (index, raw) in file.source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                var range = line.startIndex..<line.endIndex
                while let found = line.range(of: query, options: options, range: range) {
                    matches.append(ScriptMatch(fileID: file.id, fileName: file.name, line: index + 1,
                                               column: line.distance(from: line.startIndex, to: found.lowerBound) + 1,
                                               preview: line.trimmingCharacters(in: .whitespaces)))
                    if matches.count >= 500 { return matches }
                    range = found.upperBound..<line.endIndex
                }
            }
        }
        return matches
    }

    /// Every file with `query` replaced, and how many were.
    public static func replaceAll(_ query: String, with replacement: String, in files: [ScriptFile],
                                  caseSensitive: Bool = false) -> (files: [ScriptFile], count: Int) {
        guard !query.isEmpty else { return (files, 0) }
        var count = 0
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let changed = files.map { file -> ScriptFile in
            var copy = file
            let occurrences = find(query, in: [file], caseSensitive: caseSensitive).count
            guard occurrences > 0 else { return file }
            count += occurrences
            copy.source = file.source.replacingOccurrences(of: query, with: replacement, options: options)
            return copy
        }
        return (changed, count)
    }
}

// MARK: - What changed

public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case same, added, removed }
    public var kind: Kind
    public var text: String
    public var id: Int
}

public enum TextDiff {
    /// Line by line: what was taken out and what was put in.
    public static func lines(from old: String, to new: String) -> [DiffLine] {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The same at both ends needs no working out.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let midA = Array(a[head..<(a.count - tail)])
        let midB = Array(b[head..<(b.count - tail)])
        var result: [(DiffLine.Kind, String)] = a[..<head].map { (.same, $0) }
        if midA.count * midB.count > 4_000_000 {
            // Too big to line up: everything in the middle changed.
            result += midA.map { (.removed, $0) } + midB.map { (.added, $0) }
        } else {
            // Longest common subsequence, then walk it.
            var table = Array(repeating: Array(repeating: 0, count: midB.count + 1), count: midA.count + 1)
            for i in stride(from: midA.count - 1, through: 0, by: -1) {
                for j in stride(from: midB.count - 1, through: 0, by: -1) {
                    table[i][j] = midA[i] == midB[j] ? table[i + 1][j + 1] + 1 : Swift.max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < midA.count || j < midB.count {
                if i < midA.count, j < midB.count, midA[i] == midB[j] {
                    result.append((.same, midA[i])); i += 1; j += 1
                } else if j < midB.count, i == midA.count || table[i][j + 1] >= table[i + 1][j] {
                    result.append((.added, midB[j])); j += 1
                } else {
                    result.append((.removed, midA[i])); i += 1
                }
            }
        }
        result += a[(a.count - tail)...].map { (.same, $0) }
        return result.enumerated().map { DiffLine(kind: $0.element.0, text: $0.element.1, id: $0.offset) }
    }
}

// MARK: - Snippets

public struct ScriptSnippet: Hashable, Sendable, Identifiable {
    public var title: String
    public var symbolName: String
    public var code: String
    public var id: String { title }
}

public enum ScriptSnippets {
    public static var all: [ScriptSnippet] {
        [
            ScriptSnippet(title: L("When a player joins"), symbolName: "person.badge.plus", code: """
            on join(p)
              p.message("Welcome, " + p.name + "!", 3)
            end
            """),
            ScriptSnippet(title: L("A coin to collect"), symbolName: "circle.circle.fill", code: """
            on touch(p, b)
              if contains(b.tags, "coin") then
                p.score = p.score + 1
                b.destroy()
                sound("coin")
              end
            end
            """),
            ScriptSnippet(title: L("Score on the screen"), symbolName: "number", code: """
            on join(p)
              p.ui_text("score", "Score: 0", {at: "top_left", size: 22})
            end
            """),
            ScriptSnippet(title: L("Every second"), symbolName: "timer", code: """
            every(1, func()
              for p in players() do
                -- something each second
              end
            end)
            """),
            ScriptSnippet(title: L("A countdown"), symbolName: "hourglass", code: """
            on start()
              countdown(60, "Time left")
            end

            on countdown(label, p)
              end_round("Time's up!")
            end
            """),
            ScriptSnippet(title: L("A button"), symbolName: "hand.tap.fill", code: """
            on join(p)
              p.ui_button("play", "Play", {at: "bottom", w: 200, h: 56, bg: "green"})
            end

            on button(p, id)
              if id == "play" then
                p.ui_remove("play")
              end
            end
            """),
            ScriptSnippet(title: L("Give a weapon"), symbolName: "scope", code: """
            on join(p)
              p.give("blaster")
            end
            """),
            ScriptSnippet(title: L("Keep coins between visits"), symbolName: "tray.and.arrow.down.fill", code: """
            on loaded(p)
              p.coins = p.saved.coins or 0
            end

            -- when they change: p.save("coins", p.coins)
            """),
            ScriptSnippet(title: L("A shop"), symbolName: "cart.fill", code: """
            on touch(p, b)
              if b.name == "Shop" then
                p.shop("Shop", [{name: "Speed boots", price: 20, icon: "👟"}], {currency: "coins"})
              end
            end

            on buy(p, item, price)
              if item == "Speed boots" then p.speed = 1.5 end
            end
            """),
            ScriptSnippet(title: L("A talking character"), symbolName: "bubble.left.fill", code: """
            -- Give a part the name "Guide" and a behavior (trigger).
            on touch(p, b)
              if b.name == "Guide" then
                p.dialog("Guide", "Hello! Want a tip?", ["Yes", "No"])
              end
            end

            on choice(p, answer, n)
              if answer == "Yes" then p.message("Look behind the tree!", 3) end
            end
            """),
            ScriptSnippet(title: L("Best times"), symbolName: "trophy.fill", code: """
            on touch(p, b)
              if b.name == "Finish" then
                leaderboard("Fastest", p, game.time, {lower: true})
                p.show_leaderboard("Fastest")
              end
            end
            """),
            ScriptSnippet(title: L("Weather and time"), symbolName: "cloud.sun.rain.fill", code: """
            on start()
              world.time = 18
              world.day_length = 10
              world.weather = "rain"
            end
            """)
        ]
    }
}
