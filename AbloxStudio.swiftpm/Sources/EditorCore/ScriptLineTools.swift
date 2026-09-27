import Foundation

/// Editing a script a line at a time, as a code editor on a computer does:
/// comment lines out and back, copy a line, move lines up and down, list
/// the TODO notes. Positions are UTF-16 offsets, as the text view counts.
public enum ScriptLineTools {

    /// The cursor or the selected text.
    public struct Selection: Hashable, Sendable {
        public var location: Int
        public var length: Int
        public init(location: Int, length: Int = 0) {
            self.location = location
            self.length = length
        }
    }

    /// The text after an edit and where the selection goes.
    public struct Edit: Hashable, Sendable {
        public var text: String
        public var selection: Selection
    }

    /// Written before a line to comment it out: the lexer reads `--` and `#`.
    public static let commentMarker = "-- "

    // MARK: Lines

    /// Lines, and where each starts (UTF-16).
    static func lines(of text: String) -> (lines: [String], starts: [Int]) {
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        return (lines, starts)
    }

    /// First and last line (from 0) the selection touches. A selection that
    /// ends at the very start of a line does not take that line.
    static func touchedLines(_ selection: Selection, starts: [Int]) -> ClosedRange<Int> {
        func line(at offset: Int) -> Int {
            (starts.lastIndex { $0 <= offset }) ?? 0
        }
        let first = line(at: selection.location)
        var last = line(at: selection.location + selection.length)
        if selection.length > 0, last > first, starts[last] == selection.location + selection.length { last -= 1 }
        return first...last
    }

    static func indentation(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: Comments

    /// Comments the touched lines out, or back in when they all already are.
    /// Blank lines are left alone.
    public static func toggleComment(_ text: String, selection: Selection) -> Edit {
        var (lines, starts) = lines(of: text)
        let range = touchedLines(selection, starts: starts)
        let filled = range.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filled.isEmpty else { return Edit(text: text, selection: selection) }
        let allCommented = filled.allSatisfy { isComment(lines[$0]) }
        // The shallowest indentation, so a block keeps its shape.
        let column = filled.map { indentation(of: lines[$0]).count }.min() ?? 0
        var shift = 0
        var firstShift = 0
        for index in filled {
            let before = lines[index].utf16.count
            if allCommented {
                lines[index] = uncommented(lines[index])
            } else {
                let cut = lines[index].index(lines[index].startIndex, offsetBy: column)
                lines[index].insert(contentsOf: commentMarker, at: cut)
            }
            let change = lines[index].utf16.count - before
            if index == range.lowerBound { firstShift = change }
            shift += change
        }
        let newText = lines.joined(separator: "\n")
        let location = Swift.max(starts[range.lowerBound], selection.location + firstShift)
        let length = selection.length == 0 ? 0 : Swift.max(0, selection.length + shift - firstShift)
        return Edit(text: newText, selection: Selection(location: Swift.min(location, newText.utf16.count), length: length))
    }

    static func isComment(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("--") || trimmed.hasPrefix("#")
    }

    static func uncommented(_ line: String) -> String {
        let indent = indentation(of: line)
        var rest = Substring(line.dropFirst(indent.count))
        if rest.hasPrefix("--") { rest = rest.dropFirst(2) } else if rest.hasPrefix("#") { rest = rest.dropFirst(1) }
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return indent + rest
    }

    /// The code of a line, without its comment. Quotes are respected, so a
    /// `#` inside a string stays.
    public static func withoutComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character?
        var result = ""
        for character in line {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return result
            } else if character == "-" && previous == "-" {
                return String(result.dropLast())
            }
            result.append(character)
            previous = character
        }
        return result
    }

    // MARK: Copying and moving

    /// The touched lines copied just below them, the cursor on the copy.
    public static func duplicateLines(_ text: String, selection: Selection) -> Edit {
        var (lines, starts) = lines(of: text)
        let range = touchedLines(selection, starts: starts)
        let block = Array(lines[range])
        lines.insert(contentsOf: block, at: range.upperBound + 1)
        let added = block.reduce(0) { $0 + $1.utf16.count + 1 }
        return Edit(text: lines.joined(separator: "\n"),
                    selection: Selection(location: selection.location + added, length: selection.length))
    }

    /// The touched lines one line up or down, selection going with them;
    /// nil at the top or bottom.
    public static func moveLines(_ text: String, selection: Selection, up: Bool) -> Edit? {
        var (lines, starts) = lines(of: text)
        let range = touchedLines(selection, starts: starts)
        if up {
            guard range.lowerBound > 0 else { return nil }
            let above = lines.remove(at: range.lowerBound - 1)
            lines.insert(above, at: range.upperBound)
            let moved = above.utf16.count + 1
            return Edit(text: lines.joined(separator: "\n"),
                        selection: Selection(location: selection.location - moved, length: selection.length))
        } else {
            guard range.upperBound < lines.count - 1 else { return nil }
            let below = lines.remove(at: range.upperBound + 1)
            lines.insert(below, at: range.lowerBound)
            let moved = below.utf16.count + 1
            return Edit(text: lines.joined(separator: "\n"),
                        selection: Selection(location: selection.location + moved, length: selection.length))
        }
    }

    // MARK: Notes to self

    /// Words that mark a note to come back to.
    public static let noteWords = ["TODO", "FIXME", "あとで", "メモ"]

    /// Every comment with a note word, file by file.
    public static func notes(in files: [ScriptFile]) -> [ScriptMatch] {
        var found: [ScriptMatch] = []
        for file in files {
            for (index, line) in file.source.components(separatedBy: "\n").enumerated() {
                let code = withoutComment(line)
                guard code.count < line.count else { continue }
                let comment = String(line.dropFirst(code.count))
                guard let word = noteWords.first(where: { comment.localizedCaseInsensitiveContains($0) }) else { continue }
                let column = (line.range(of: word, options: .caseInsensitive).map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? code.count) + 1
                found.append(ScriptMatch(fileID: file.id, fileName: file.name, line: index + 1, column: column,
                                         preview: comment.trimmingCharacters(in: CharacterSet(charactersIn: "-# ").union(.whitespaces))))
            }
        }
        return found
    }

    /// The number of lines, for "Go to line".
    public static func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }
}
