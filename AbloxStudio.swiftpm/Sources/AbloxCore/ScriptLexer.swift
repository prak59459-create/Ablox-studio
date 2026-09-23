import Foundation

// MARK: - AbloxScript
//
// The language worlds are programmed in: first-person cameras, weapons,
// on-screen buttons, rounds, scores — anything the block behaviours and the
// rule editor cannot say.
//
// ## Why not Swift
//
// Because it cannot run. iOS does not let a running app compile or load new
// native code, and Swift Playgrounds compiles the app itself, not code the app
// is handed later. A world's program has to be interpreted.
//
// ## Why not JavaScriptCore
//
// It is an Apple framework and would run on the iPad — but:
//
// - it does not exist on Linux, so nothing about scripting could be tested
//   off-device, which is the only place anything in this project is tested;
// - there is no public way to stop `while (true) {}`. Worlds arrive from
//   strangers through the game catalogue and run *on the host*, so one hostile
//   loop would freeze every host that opened it. This interpreter counts every
//   step and stops a handler that runs too long;
// - error messages have to name a line and make sense to a child, in Japanese
//   as well as English.
//
// ## The shape of it
//
// Lua-like, because it reads aloud: `if … then … end`, `for i in 1 to 10 do`,
// `on hit(attacker, victim) … end`. Lists count from 1, as in Scratch.
// Identifiers may be in any script, so `let 体力 = 100` works.
//
// The pipeline is `ScriptLexer` → `ScriptParser` → `ScriptInterpreter`, all in
// the portable core; the game API on top is `GameRuntime`.

/// A token, with where it came from.
public struct ScriptToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case identifier(String)
        case number(Double)
        case string(String)
        case keyword(Keyword)
        case symbol(Symbol)
        case end
    }

    public let kind: Kind
    public let line: Int

    public init(_ kind: Kind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

public enum Keyword: String, CaseIterable, Sendable {
    case `let`, `if`, then, elif, `else`, end, `while`, `do`, `for`, `in`, to, step
    case `func`, `return`, on, and, or, not, `true`, `false`, `nil`, `break`, `continue`
}

public enum Symbol: String, CaseIterable, Sendable {
    // Two characters first: the lexer tries the longest match.
    case equalEqual = "==", bangEqual = "!=", lessEqual = "<=", greaterEqual = ">=", dotDot = ".."
    case plus = "+", minus = "-", star = "*", slash = "/", percent = "%"
    case less = "<", greater = ">", equal = "="
    case leftParen = "(", rightParen = ")", leftBracket = "[", rightBracket = "]"
    case leftBrace = "{", rightBrace = "}", comma = ",", dot = ".", colon = ":"
}

/// Turns source text into tokens.
public enum ScriptLexer {

    /// The longest one `.absc` file may be. Generous — a whole game fits in
    /// one — and still bounded, because a world file carries its scripts and
    /// the catalogue limits worlds to 8 MB.
    public static let maximumSourceLength = 1_000_000

    /// - Parameter file: which file of a bundle this is, so every line
    ///   number can say which file it is in. See `ScriptLocation`.
    public static func tokens(from source: String, file: Int? = nil) throws -> [ScriptToken] {
        guard source.count <= maximumSourceLength else {
            throw ScriptError(line: ScriptLocation.pack(line: 1, file: file), kind: .syntax, message: L("The script is too long."))
        }

        var tokens: [ScriptToken] = []
        let characters = Array(source)
        var index = 0
        var line = ScriptLocation.pack(line: 1, file: file)

        func peek(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        /// Outside text values, full-width letters, digits and symbols are
        /// read as their plain versions — see `ScriptLexer.plain`.
        func peekPlain(_ offset: Int = 0) -> Character? {
            peek(offset).map(plain)
        }

        while let character = peekPlain() {
            // Whitespace, including newlines. Statements are separated by
            // their keywords, as in Lua, so a line break carries no meaning —
            // which means a long expression can be split over lines freely.
            if character == "\n" {
                line += 1
                index += 1
                continue
            }
            if character.isWhitespace {
                index += 1
                continue
            }

            // Comments: `--` or `#` to the end of the line. Both, because
            // children arrive having seen one or the other.
            if character == "#" || (character == "-" && peek(1) == "-") {
                while let next = peek(), next != "\n" { index += 1 }
                continue
            }

            // Numbers. A leading digit only, so `.5` is a member access on
            // nothing rather than an ambiguous half.
            if character.isASCII && character.isNumber {
                let start = index
                while let next = peekPlain(), next.isASCII && next.isNumber { index += 1 }
                // A decimal point only when a digit follows, so `1..5` stays
                // a range-ish concatenation rather than `1.` then `.5`.
                if peekPlain() == ".", let after = peekPlain(1), after.isASCII && after.isNumber {
                    index += 1
                    while let next = peekPlain(), next.isASCII && next.isNumber { index += 1 }
                }
                let text = String(characters[start..<index].map(plain))
                guard let value = Double(text), value.isFinite else {
                    throw ScriptError(line: line, kind: .syntax, message: L("“{}” is not a number.", text))
                }
                tokens.append(ScriptToken(.number(value), line: line))
                continue
            }

            // Identifiers and keywords. Any letter in any script, so a child
            // can name things in their own language.
            if character.isLetter || character == "_" {
                let start = index
                while let next = peekPlain(), next.isLetter || next.isNumber || next == "_" { index += 1 }
                let word = String(characters[start..<index].map(plain))
                if let keyword = Keyword(rawValue: word) {
                    tokens.append(ScriptToken(.keyword(keyword), line: line))
                } else {
                    tokens.append(ScriptToken(.identifier(word), line: line))
                }
                continue
            }

            // Strings, in either quote. One line only: an unclosed quote is
            // then an error on the line where it happened, rather than the
            // whole rest of the file silently becoming one string.
            //
            // Curly quotes count too. The iPad keyboard turns " into “ as you
            // type, and "“ cannot be used here" would be a baffling first
            // error for a child who typed exactly what the example showed.
            if let closers = closingQuotes(for: character) {
                let startLine = line
                index += 1
                var value = ""
                var closed = false
                while let next = peek() {
                    if next == "\n" { break }
                    if closers.contains(next) { index += 1; closed = true; break }
                    if next == "\\" {
                        index += 1
                        switch peek() {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "\\": value.append("\\")
                        case "\"": value.append("\"")
                        case "'": value.append("'")
                        case let other?: value.append("\\"); value.append(other)
                        case nil: break
                        }
                        index += 1
                        continue
                    }
                    value.append(next)
                    index += 1
                }
                guard closed else {
                    throw ScriptError(line: startLine, kind: .syntax, message: L("A text value was never closed with a quote."))
                }
                tokens.append(ScriptToken(.string(value), line: line))
                continue
            }

            // Symbols, longest first.
            if let next = peekPlain(1), let symbol = Symbol(rawValue: String([character, next])) {
                tokens.append(ScriptToken(.symbol(symbol), line: line))
                index += 2
                continue
            }
            if let symbol = Symbol(rawValue: String(character)) {
                tokens.append(ScriptToken(.symbol(symbol), line: line))
                index += 1
                continue
            }

            throw ScriptError(line: line, kind: .syntax, message: L("“{}” cannot be used here.", String(character)))
        }

        tokens.append(ScriptToken(.end, line: line))
        return tokens
    }

    /// The plain ASCII version of a full-width character, or the character.
    ///
    /// A Japanese keyboard left in full-width mode types （ ） ＝ １ and a
    /// full-width space. They look right, and without this every one of them
    /// would be an error that the child cannot see the cause of.
    static func plain(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return character }
        switch scalar.value {
        case 0xFF01...0xFF5E:
            return Character(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
        case 0x3000:
            return " "
        default:
            return character
        }
    }

    /// What may close a text value opened with `character`, or nil when it
    /// does not open one.
    static func closingQuotes(for character: Character) -> Set<Character>? {
        switch character {
        case "\"", "“", "”", "„": return ["\"", "“", "”", "＂"]
        case "'", "‘", "’": return ["'", "‘", "’"]
        default: return nil
        }
    }
}

// MARK: - Errors

/// Something wrong with a script, and where.
///
/// Always a line and a sentence. The person reading it may be ten years old
/// and reading it on a phone-sized panel, so the message says what to do where
/// that is knowable — "did you mean `tick`?" — rather than what the parser was
/// expecting.
public struct ScriptError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The text does not form a program.
        case syntax
        /// The program did something impossible while running.
        case runtime
        /// It ran too long, recursed too deep, or grew too big.
        case limit
    }

    public let line: Int
    public let kind: Kind
    public let message: String
    /// The `.absc` file it is in, once known.
    public let file: String?

    public init(line: Int, kind: Kind, message: String, file: String? = nil) {
        self.line = line
        self.kind = kind
        self.message = message
        self.file = file
    }

    public var description: String {
        if let file { return L("{}, line {}: {}", file, line, message) }
        return L("Line {}: {}", line, message)
    }

    /// Unpacks a bundle location into the file's name and its own line.
    public func resolved(files: [String]) -> ScriptError {
        guard file == nil, let index = ScriptLocation.file(line), index < files.count else { return self }
        return ScriptError(line: ScriptLocation.line(line), kind: kind, message: message, file: files[index])
    }
}

/// Where a token came from, packed into the one `Int` every syntax node
/// already carries.
///
/// A world has several `.absc` files, run as one program. Giving every node a
/// file field as well would touch every line of the parser and interpreter;
/// packing the file into the high bits of the line touches neither, and a
/// script with no file (the tests, a single snippet) keeps plain line numbers.
public enum ScriptLocation {
    static let shift = 20
    static let mask = (1 << 20) - 1

    public static func pack(line: Int, file: Int?) -> Int {
        guard let file else { return line }
        return ((file + 1) << shift) | (line & mask)
    }

    /// The line within its own file.
    public static func line(_ packed: Int) -> Int {
        packed & mask
    }

    /// Which file, or nil for a script that is not part of a bundle.
    public static func file(_ packed: Int) -> Int? {
        let index = packed >> shift
        return index == 0 ? nil : index - 1
    }
}
