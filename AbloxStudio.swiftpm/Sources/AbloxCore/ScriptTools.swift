import Foundation

// What Studio's script editor needs from the language itself: colours for
// the code, breakpoints that show the variables where a line runs, the cost
// of each handler, and robots that play a test run.

// MARK: - Colouring the code

public enum ScriptHighlighter {

    public enum Kind: String, Sendable, CaseIterable {
        case keyword, string, number, comment, event, builtin
    }

    public struct Span: Hashable, Sendable {
        public var range: NSRange
        public var kind: Kind
    }

    public static let keywords: Set<String> = [
        "let", "if", "then", "elif", "else", "end", "for", "in", "to", "step", "do", "while", "break", "continue",
        "func", "return", "on", "and", "or", "not", "true", "false", "nil"
    ]

    private static let pattern: NSRegularExpression = {
        // Comments first, then strings, so neither is coloured inside the other.
        // Both kinds of comment (`--` and `#`) and every quote the lexer
        // reads: straight double and single, and the curly ones the iPad
        // keyboard types.
        try! NSRegularExpression(pattern: #"((?:--|#)[^\n]*)|("(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?|[“”„](?:\\.|[^"“”＂\\\n])*["“”＂]?|[‘’](?:\\.|[^'‘’\\\n])*['‘’]?)|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][A-Za-z0-9_]*\b)"#)
    }()

    /// Everything worth colouring, in order. Very long text is left plain:
    /// colouring it on every keystroke would make typing lag.
    public static func spans(in text: String, builtins: Set<String> = []) -> [Span] {
        let ns = text as NSString
        guard ns.length <= 120_000 else { return [] }
        var spans: [Span] = []
        var afterOn = false
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound {
                spans.append(Span(range: match.range(at: 1), kind: .comment))
            } else if match.range(at: 2).location != NSNotFound {
                spans.append(Span(range: match.range(at: 2), kind: .string))
            } else if match.range(at: 3).location != NSNotFound {
                spans.append(Span(range: match.range(at: 3), kind: .number))
            } else {
                let range = match.range(at: 4)
                let word = ns.substring(with: range)
                if keywords.contains(word) {
                    spans.append(Span(range: range, kind: .keyword))
                    afterOn = word == "on"
                    continue
                }
                if afterOn {
                    spans.append(Span(range: range, kind: .event))
                } else if builtins.contains(word) {
                    spans.append(Span(range: range, kind: .builtin))
                }
            }
            afterOn = false
        }
        return spans
    }

    /// Where line `line` (from 1) starts and ends in `text`.
    public static func range(ofLine line: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        var current = 1
        var start = 0
        while current < line {
            let next = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard next.location != NSNotFound else { return nil }
            start = next.location + 1
            current += 1
        }
        guard start <= ns.length else { return nil }
        let end = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
        return NSRange(location: start, length: (end.location == NSNotFound ? ns.length : end.location) - start)
    }
}

// MARK: - Breakpoints

/// A line to stop and look at in a test run.
public struct ScriptBreakpoint: Hashable, Sendable {
    public var file: String
    public var line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

/// What the variables were when a breakpoint's line ran.
public struct BreakpointHit: Hashable, Sendable {
    public var file: String
    public var line: Int
    /// Seconds into the test run.
    public var time: Double
    /// Innermost first; each value as `print` would show it.
    public var variables: [Variable]

    public struct Variable: Hashable, Sendable {
        public var name: String
        public var value: String
    }

    /// Nearest names first, the globals last; built-in functions left out.
    static func variables(in scope: ScriptScope, hiding hidden: Set<String>) -> [Variable] {
        var found: [Variable] = []
        var seen: Set<String> = []
        var current: ScriptScope? = scope
        while let level = current, found.count < 40 {
            for name in level.values.keys.sorted() where !seen.contains(name) && !hidden.contains(name) {
                seen.insert(name)
                guard let value = level.values[name] else { continue }
                if level.parent == nil {
                    if case .function = value { continue }
                    if case .native = value { continue }
                }
                found.append(Variable(name: name, value: String(value.displayText.prefix(80))))
            }
            current = level.parent
        }
        return Array(found.prefix(40))
    }
}

/// One handler's share of a test run.
public struct HandlerCost: Hashable, Sendable, Identifiable {
    public var name: String
    public var calls = 0
    public var steps = 0
    public var seconds: Double = 0

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Robots for a test run

/// Two players that play a test run: every half second each walks onto the
/// next block that does something when touched, and presses a button on its
/// screen it has not pressed yet.
struct TestRobots {
    let players: [PeerID]
    private var targets: [UUID]
    private var next: [PeerID: Int] = [:]
    private var pressed: Set<String> = []
    private var clock = 0.0
    private var touches = 0
    private var presses = 0
    private var screens: [PeerID: ScriptedPlayerState] = [:]
    private var seen = 0

    init(players: [PeerID], world: WorldDocument) {
        self.players = players
        targets = world.blocks.filter { $0.isVisible && ($0.behavior.needsTouchDetection || !$0.tags.isEmpty) }.map(\.id)
    }

    mutating func play(_ game: GameRuntime, effects: [GameRuntime.Effect], at time: Double) -> [GameRuntime.Effect] {
        // Keep each robot's screen up to date, so it knows its buttons.
        for effect in effects.dropFirst(seen) {
            guard case let .script(change) = effect.action else { continue }
            for peer in players where effect.targetPeerID == nil || effect.targetPeerID == peer {
                screens[peer, default: ScriptedPlayerState()].apply(change)
            }
        }
        seen = effects.count
        guard time - clock >= 0.5 else { return [] }
        clock = time
        var made: [GameRuntime.Effect] = []
        for peer in players {
            if !targets.isEmpty {
                let index = next[peer, default: players.firstIndex(of: peer) ?? 0] % targets.count
                next[peer] = index + 1
                let id = targets[index]
                if let position = game.world.block(id: id).map({ game.world.worldPosition(of: $0.id) }) {
                    game.updateTransform(PlayerTransformPayload(peerID: peer, position: position + Vec3(0, 0.5, 0), yawDegrees: 0))
                    made += game.handle(.touched(peer: peer, blockID: id))
                    touches += 1
                }
            }
            let buttons = (screens[peer]?.ui ?? []).filter { $0.kind == .button && $0.visible }
            if let button = buttons.first(where: { !pressed.contains("\(peer)|\($0.id)") }) {
                pressed.insert("\(peer)|\(button.id)")
                made += game.handle(.button(id: button.id), from: peer, at: time)
                presses += 1
            }
        }
        return made
    }

    var summary: [String] {
        [L("The robots touched blocks {} times and pressed {} buttons.", touches, presses)]
    }
}
