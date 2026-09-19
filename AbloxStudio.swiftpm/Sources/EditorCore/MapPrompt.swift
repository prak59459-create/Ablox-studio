import Foundation

/// The text Studio hands to an assistant when you ask it for a level.
///
/// ## Why a prompt and not an API call
///
/// Ablox has no server, no account and no key, and its own Settings screen
/// tells people nothing leaves their network. Wiring in a cloud model would
/// contradict all of that for a feature nobody needs to be automatic. So
/// Studio writes the prompt, the person pastes it wherever they already talk
/// to an assistant, and pastes the answer back. It costs nothing, works with
/// whichever assistant they have, and keeps the app's promise intact.
///
/// ## The prompt is generated, not written
///
/// Every list in it — the parts, the behaviours, the colours — comes from
/// `allCases` at the moment the prompt is built, and the physics numbers come
/// from `MovementConfig`. That matters more than it sounds: a prompt that
/// names a part the palette does not have produces a plan that fails to
/// import, and a prompt that says "you can jump 2 m" produces a level nobody
/// can finish. Neither can happen if the prompt cannot be written by hand.
///
/// `MapPromptTests` asserts exactly that — every vocabulary word in the prompt
/// resolves, and every number matches what the simulation actually does.
public enum MapPrompt {

    public struct Request: Equatable, Sendable {
        public var theme: String
        public var size: Size
        public var difficulty: Difficulty
        public var includeCoins: Bool
        public var includeHazards: Bool
        public var includeGimmicks: Bool

        public init(
            theme: String = "",
            size: Size = .medium,
            difficulty: Difficulty = .normal,
            includeCoins: Bool = true,
            includeHazards: Bool = true,
            includeGimmicks: Bool = false
        ) {
            self.theme = theme
            self.size = size
            self.difficulty = difficulty
            self.includeCoins = includeCoins
            self.includeHazards = includeHazards
            self.includeGimmicks = includeGimmicks
        }
    }

    public enum Size: String, CaseIterable, Identifiable, Sendable {
        case small, medium, large

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .small: return L("Small")
            case .medium: return L("Medium")
            case .large: return L("Large")
            }
        }

        /// Part counts an assistant can actually hit. Asking for "about 40"
        /// gets something near 40; asking for "a lot" gets anything.
        public var partCount: Int {
            switch self {
            case .small: return 25
            case .medium: return 60
            case .large: return 140
            }
        }
    }

    public enum Difficulty: String, CaseIterable, Identifiable, Sendable {
        case gentle, normal, hard

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .gentle: return L("Gentle")
            case .normal: return L("Normal")
            case .hard: return L("Hard")
            }
        }

        /// How much of a full jump a gap may use. Kept well under 1 even at
        /// the top, because a gap that needs a perfect jump is not hard, it is
        /// annoying.
        public var gapFraction: Float {
            switch self {
            case .gentle: return 0.45
            case .normal: return 0.70
            case .hard: return 0.90
            }
        }
    }

    // MARK: Building

    /// The complete prompt, ready to paste into an assistant.
    public static func text(for request: Request, movement: MovementConfig = .default) -> String {
        let jumpHeight = round(movement.maximumJumpHeight * 100) / 100
        let jumpGap = round(movement.safeJumpDistance * request.difficulty.gapFraction * 10) / 10

        var lines: [String] = []

        lines.append(L("You are designing a level for Ablox, a block-building game on iPad."))
        lines.append("")
        lines.append(L("Reply with one JSON object and nothing else — no explanation, no code fence."))
        lines.append("")

        // --- What to make -------------------------------------------------
        lines.append(L("## What to make"))
        lines.append("")
        if !request.theme.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(L("Theme: {}", request.theme.trimmingCharacters(in: .whitespaces)))
        }
        lines.append(L("About {} parts.", request.size.partCount))
        lines.append(L("Difficulty: {}.", request.difficulty.displayName))
        lines.append(L("The player walks from a start pad to a goal. Make that route obvious."))
        lines.append("")

        // --- The format ---------------------------------------------------
        lines.append(L("## Format"))
        lines.append("")
        lines.append("```json")
        lines.append(example)
        lines.append("```")
        lines.append("")
        lines.append(L("`kind` must be one of: {}", MapPlan.partVocabulary))
        lines.append(L("`behavior` is optional and must be one of: {}", MapPlan.behaviourVocabulary))
        lines.append(L("`color` is optional, as #RRGGBB. `width`, `height`, `depth` and `yaw` are optional too."))
        lines.append("")

        // --- The world it lands in ----------------------------------------
        lines.append(L("## The world"))
        lines.append("")
        lines.append(L("Coordinates are metres. Y is up. The floor is at y = 0 and is 40 by 40."))
        lines.append(L("A part's x, y and z are its centre, so a 1 m tall block resting on the floor has y = 0.5."))
        lines.append(L("Keep everything within 100 m of the origin."))
        lines.append("")

        // --- What a player can do -----------------------------------------
        lines.append(L("## What a player can do"))
        lines.append("")
        lines.append(L("A jump rises {} m. Never make a step taller than that.", jumpHeight))
        lines.append(L("A running jump crosses about {} m. Keep gaps at or under that.", jumpGap))
        lines.append(L("Players fall off the edge, so put a floor or a platform under every route."))
        lines.append("")

        // --- Rules ---------------------------------------------------------
        lines.append(L("## Rules"))
        lines.append("")
        lines.append(L("Exactly one part with behavior \"spawn\". Put it on the floor."))
        lines.append(L("Exactly one part with behavior \"goal\", at the end of the route."))
        for rule in featureRules(for: request) {
            lines.append(rule)
        }
        lines.append(L("Every part must be reachable from the spawn."))
        lines.append(L("Do not overlap parts. Two blocks in the same place look like one broken block."))

        return lines.joined(separator: "\n")
    }

    private static func featureRules(for request: Request) -> [String] {
        var rules: [String] = []

        if request.includeCoins {
            rules.append(L("Put a few \"orb\" parts along the route, slightly off the easy path."))
        }
        if request.includeHazards {
            rules.append(L("Use \"hazard\" parts to make the route risky."))
            rules.append(L("Put a \"checkpoint\" part before each hazard, or a mistake costs the whole run."))
        }
        if request.includeGimmicks {
            rules.append(L("You may use behavior \"bounce\", \"disappear\" or \"teleport\" on ordinary parts."))
            rules.append(L("A \"bounce\" part launches the player upward — use it to reach a height a jump cannot."))
        }
        return rules
    }

    /// A tiny worked example, so the shape is unambiguous.
    ///
    /// Two parts rather than one: a single-element array is the shape people
    /// and models alike get wrong.
    public static var example: String {
        """
        {
          "name": "Sky Steps",
          "summary": "Climb the towers and reach the gate.",
          "parts": [
            { "kind": "spawn", "x": 0, "y": 0.1, "z": 8 },
            { "kind": "platform", "x": 0, "y": 0.25, "z": 4, "width": 6, "height": 0.5, "depth": 6, "color": "#37474F" },
            { "kind": "block", "x": 0, "y": 0.5, "z": 0, "width": 3, "height": 1, "depth": 2, "behavior": "none" },
            { "kind": "orb", "x": 0, "y": 2, "z": -2 },
            { "kind": "goal", "x": 0, "y": 1.5, "z": -6 }
          ]
        }
        """
    }

    /// What to say when an import failed, ready to paste back.
    ///
    /// The problems are already phrased as instructions, so this only has to
    /// frame them — and framing matters: "fix these and send the whole thing
    /// again" avoids getting a patch back that cannot be pasted anywhere.
    public static func correction(for problems: [MapPlanProblem]) -> String {
        var lines = [L("That did not import. Fix these and send the whole JSON again:"), ""]
        for problem in problems {
            lines.append("- \(problem.description)")
        }
        return lines.joined(separator: "\n")
    }
}
