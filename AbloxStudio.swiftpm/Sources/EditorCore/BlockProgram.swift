import Foundation

/// Programming with blocks: "when … do …" cards, each a list of actions
/// picked from a menu, for the players who are not ready to type code.
///
/// A block program is kept in an ordinary `.absc` file — its first line is
/// a comment carrying the cards, the rest is the code they make — so it runs
/// like any script, travels with the world, and can be opened as code once
/// its maker is ready.
public struct BlockProgram: Codable, Hashable, Sendable {

    public static let marker = "-- ablox-blocks: "

    public enum Trigger: String, Codable, CaseIterable, Sendable, Identifiable {
        case start, join, touch, button, every, chat
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .start: return L("When the game starts")
            case .join: return L("When a player joins")
            case .touch: return L("When a player touches a part")
            case .button: return L("When a button is pressed")
            case .every: return L("Every few seconds")
            case .chat: return L("When a player says")
            }
        }

        public var symbolName: String {
            switch self {
            case .start: return "flag.fill"
            case .join: return "person.badge.plus"
            case .touch: return "hand.point.up.left.fill"
            case .button: return "hand.tap.fill"
            case .every: return "timer"
            case .chat: return "bubble.left.fill"
            }
        }

        /// What the trigger's box asks for.
        public var asks: String? {
            switch self {
            case .touch: return L("Part name (empty: any part)")
            case .button: return L("Button id")
            case .every: return L("Seconds")
            case .chat: return L("Word")
            case .start, .join: return nil
            }
        }
    }

    public enum Action: String, Codable, CaseIterable, Sendable, Identifiable {
        case message, announce, addScore, sound, particles, teleport, launch, speed, jump, giveWeapon
        case showText, showButton, hidePart, showPart, colorPart
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .message: return L("Tell the player")
            case .announce: return L("Tell everyone")
            case .addScore: return L("Add to their score")
            case .sound: return L("Play a sound")
            case .particles: return L("Make particles")
            case .teleport: return L("Send them to a part")
            case .launch: return L("Launch them up")
            case .speed: return L("Set their speed")
            case .jump: return L("Set their jump")
            case .giveWeapon: return L("Give a weapon")
            case .showText: return L("Show text on their screen")
            case .showButton: return L("Show a button")
            case .hidePart: return L("Hide a part")
            case .showPart: return L("Show a part")
            case .colorPart: return L("Colour a part")
            }
        }

        /// Whether it needs a player (in "when the game starts", it is done
        /// for everyone who is there).
        var needsPlayer: Bool {
            switch self {
            case .announce, .hidePart, .showPart, .colorPart: return false
            default: return true
            }
        }

        /// What its boxes ask for: text, a number, a part.
        public var asksText: String? {
            switch self {
            case .message, .announce, .showText: return L("Words")
            case .sound: return L("Sound (coin, win, jump…)")
            case .particles: return L("Particles (confetti, fire…)")
            case .giveWeapon: return L("Weapon (blaster, rifle…)")
            case .showButton: return L("Button id")
            case .colorPart: return L("Colour (red, #FF8800…)")
            default: return nil
            }
        }

        public var asksNumber: String? {
            switch self {
            case .addScore: return L("Points")
            case .launch: return L("How high")
            case .speed, .jump: return L("Times normal")
            default: return nil
            }
        }

        public var asksPart: Bool {
            switch self {
            case .teleport, .hidePart, .showPart, .colorPart: return true
            default: return false
            }
        }
    }

    public struct Step: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var action: Action
        public var text = ""
        public var number: Double = 1
        public var part = ""

        public init(action: Action, text: String = "", number: Double = 1, part: String = "") {
            self.action = action
            self.text = text
            self.number = number
            self.part = part
        }
    }

    public struct Card: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var trigger: Trigger
        /// The part, button, seconds or word the trigger asks for.
        public var value = ""
        public var steps: [Step] = []

        public init(trigger: Trigger, value: String = "", steps: [Step] = []) {
            self.trigger = trigger
            self.value = value
            self.steps = steps
        }
    }

    public var cards: [Card] = []

    public init(cards: [Card] = []) {
        self.cards = cards
    }

    // MARK: Keeping it in a file

    /// The program in a file, or nil when the file was not made with blocks.
    public init?(file: ScriptFile) {
        guard let first = file.source.split(separator: "\n", maxSplits: 1).first, first.hasPrefix(Self.marker),
              let data = Data(base64Encoded: String(first.dropFirst(Self.marker.count))),
              let program = try? JSONDecoder().decode(BlockProgram.self, from: data) else { return nil }
        self = program
    }

    /// The whole file: the cards, then the code they make.
    public var fileSource: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.marker + data.base64EncodedString() + "\n" + source
    }

    // MARK: Making the code

    /// The `.absc` the cards stand for.
    public var source: String {
        var lines = ["-- Made with blocks in Ablox Studio. Edit it here as blocks, or turn it into code."]
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        func number(_ value: Double) -> String {
            value.isFinite ? ScriptValue.format(value) : "0"
        }
        func code(_ step: Step) -> String {
            switch step.action {
            case .message: return "p.message(\(quoted(step.text)), 3)"
            case .announce: return "announce(\(quoted(step.text)), 3)"
            case .addScore: return "p.score = p.score + \(number(step.number))"
            case .sound: return "p.sound(\(quoted(step.text.isEmpty ? "coin" : step.text.lowercased())))"
            case .particles: return "particles(\(quoted(step.text.isEmpty ? "confetti" : step.text.lowercased())), p)"
            case .teleport: return "p.teleport(block(\(quoted(step.part))))"
            case .launch: return "p.launch(0, \(number(step.number)), 0)"
            case .speed: return "p.speed = \(number(step.number))"
            case .jump: return "p.jump = \(number(step.number))"
            case .giveWeapon: return "p.give(\(quoted(step.text.isEmpty ? "blaster" : step.text.lowercased())))"
            case .showText: return "p.ui_text(\"blocks_text\", \(quoted(step.text)), {at: \"top\", size: 24})"
            case .showButton:
                let id = step.text.isEmpty ? "button" : step.text
                return "p.ui_button(\(quoted(id)), \(quoted(id)), {at: \"bottom\", w: 200, h: 56})"
            case .hidePart: return "block(\(quoted(step.part))).visible = false"
            case .showPart: return "block(\(quoted(step.part))).visible = true"
            case .colorPart: return "block(\(quoted(step.part))).color = \(quoted(step.text.isEmpty ? "red" : step.text))"
            }
        }
        /// The steps of a card with a player `p`; `indent` deep.
        func body(_ steps: [Step], indent: String) -> [String] {
            steps.filter { !$0.action.asksPart || !$0.part.isEmpty }.map { indent + code($0) }
        }
        /// Steps where nobody in particular did anything: for everyone.
        func forEveryone(_ steps: [Step], indent: String) -> [String] {
            let usable = steps.filter { !$0.action.asksPart || !$0.part.isEmpty }
            let alone = usable.filter { !$0.action.needsPlayer }.map { indent + code($0) }
            let each = usable.filter(\.action.needsPlayer)
            guard !each.isEmpty else { return alone }
            return alone + [indent + "for p in players() do"] + each.map { indent + "  " + code($0) } + [indent + "end"]
        }

        // One handler per event; a card that asks for a part, a button or a
        // word is an `if` inside it.
        let grouped = Dictionary(grouping: cards, by: \.trigger)
        let starts = (grouped[.start] ?? []) + (grouped[.every] ?? [])
        if !starts.isEmpty {
            lines += ["", "on start()"]
            for card in grouped[.start] ?? [] { lines += forEveryone(card.steps, indent: "  ") }
            for card in grouped[.every] ?? [] {
                let seconds = Swift.max(0.2, Double(card.value.replacingOccurrences(of: ",", with: ".")) ?? 1)
                lines += ["  every(\(number(seconds)), func()"] + forEveryone(card.steps, indent: "    ") + ["  end)"]
            }
            lines.append("end")
        }
        if let joins = grouped[.join], !joins.isEmpty {
            lines += ["", "on join(p)"] + joins.flatMap { body($0.steps, indent: "  ") } + ["end"]
        }
        let conditional: [(Trigger, String, (String) -> String)] = [
            (.touch, "on touch(p, b)", { $0.isEmpty ? "true" : "b.name == \(quoted($0))" }),
            (.button, "on button(p, id)", { "id == \(quoted($0))" }),
            (.chat, "on chat(p, text)", { "lower(trim(text)) == \(quoted($0.lowercased()))" })
        ]
        for (trigger, header, condition) in conditional {
            guard let group = grouped[trigger], !group.isEmpty else { continue }
            lines += ["", header]
            for card in group {
                lines += ["  if \(condition(card.value.trimmingCharacters(in: .whitespaces))) then"]
                    + body(card.steps, indent: "    ") + ["  end"]
            }
            lines.append("end")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
