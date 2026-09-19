import Foundation

/// "How to make a map" — the text of Studio's built-in guide.
///
/// ## Why it is data and not a view
///
/// The same words are needed in two places: the guide sheet inside Studio, and
/// `docs/making-maps.md` in the repository. Written twice they drift, and the
/// one that drifts is always the one nobody opened recently.
///
/// So they live here, in a module that compiles on Linux, and
/// `MapGuideTests` asserts three things CI can actually check:
///
/// 1. `docs/making-maps.md` is exactly what `markdown` produces;
/// 2. every part in the palette and every block behaviour is explained, by
///    walking `allCases` rather than a hand-written list — so adding one fails
///    the build until it is documented;
/// 3. the guide never names a tool, part or behaviour that does not exist.
///
/// Point 3 is the one that matters most. A guide that describes a button that
/// is not there is worse than no guide: it sends someone hunting for it.
public enum MapGuide {

    public struct Step: Equatable, Sendable {
        public var text: String
        /// Optional short aside — the thing you only find out by doing it.
        public var aside: String?

        public init(_ text: String, aside: String? = nil) {
            self.text = text
            self.aside = aside
        }
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var symbolName: String
        public var summary: String
        public var steps: [Step]

        public init(title: String, symbolName: String, summary: String, steps: [Step]) {
            self.title = title
            self.symbolName = symbolName
            self.summary = summary
            self.steps = steps
        }
    }

    // MARK: - Content

    public static var sections: [Section] {
        [
            start,
            placing,
            arranging,
            appearance,
            behaviours,
            gimmicks,
            rules,
            testing,
            together,
            finishing
        ]
    }

    private static var start: Section { Section(
        title: L("Start a world"),
        symbolName: "square.grid.2x2",
        summary: L("Every map is one world file. Studio keeps them for you and saves as you work."),
        steps: [
            Step(L("From the project list, tap the new-project button, name the world, and pick a template.")),
            Step(L("Obstacle Course starts you with a floor, a spawn pad, stairs, a coin and a finish line — it already works if you press Play. Blank gives you a floor and a spawn point."),
                aside: L("Starting from Obstacle Course and taking things away is usually faster than starting from Blank, because the pieces are already wired up for you to copy.")
            ),
            Step(L("Build on the grid you land on. It is the floor, and it is not a block — you cannot select or delete it.")),
            Step(L("There is no Save button. Studio saves shortly after you stop editing, when you press Play, and when you go back to the project list."),
                aside: L("The dot beside the world's name in the toolbar means there are changes not yet written. Saving is delayed on purpose: dragging a part makes an edit every frame, and writing all of them to storage would wear it out for no benefit.")
            )
        ]
    ) }

    private static var placing: Section { Section(
        title: L("Put parts in"),
        symbolName: "plus.circle",
        summary: L("The palette along the bottom of the viewport is where every part comes from."),
        steps: [
            Step(L("Tap a part in the palette and it lands in front of the camera."),
                aside: L("It is placed where you are looking at the moment you tap, not at the world origin — so aim first, then tap.")
            ),
            Step(L("The new part is selected straight away, so the Inspector on the right is already showing it.")),
            Step(L("Tap the chevron above the palette to fold it away when you need the room."),
                aside: L("Parts land on the grid, so two of the same kind placed side by side line up exactly.")
            )
        ]
    ) }

    private static var arranging: Section { Section(
        title: L("Move, turn, resize"),
        symbolName: "move.3d",
        summary: L("Four tools in the toolbar. Pick one, then drag the part."),
        steps: [
            Step(L("Select picks parts. Tap a part to select it; tap with two fingers to add it to the selection instead of replacing it."),
                aside: L("Nothing is selectable in Play mode — the editing gestures are switched off there entirely.")
            ),
            Step(L("Move, Rotate and Scale each drag the selected parts along the ground or around their centre.")),
            Step(L("The grid button snaps position to 0.25, 0.5, 1 or 2 metres. The angle button snaps rotation to 15°, 45° or 90°. Both have an Off setting."),
                aside: L("Off is for fine adjustment only — platforms that do not line up on the grid leave gaps a player can fall through.")
            ),
            Step(L("Undo and Redo go back through everything, including deletes.")),
            Step(L("Duplicate and Delete are in the Inspector's Actions group, and in the menu you get by pressing and holding a row in the Explorer list."),
                aside: L("Duplicating a group copies its children and keeps their internal parent links, so copying a whole staircase gives you a staircase, not nine loose steps.")
            ),
            Step(L("In the Explorer, drag one row onto another to make it a child. Moving the parent then moves the child with it."),
                aside: L("Group the parts you will want to copy or move as a unit before you build the second one — that is what turns one staircase into a tower.")
            )
        ]
    ) }

    private static var appearance: Section { Section(
        title: L("Make it look right"),
        symbolName: "paintpalette",
        summary: L("The Inspector on the right edits whatever is selected."),
        steps: [
            Step(L("Name each part as you go. The Explorer list and every rule refer to parts by name.")),
            Step(L("Colour and material change how a part is lit. Neon glows without needing a light; glass is see-through.")),
            Step(L("Anchored keeps a part still. Turn it off and the part falls in Play mode."),
                aside: L("Almost everything you build should stay anchored. Unanchored parts are for the one crate you meant to knock over.")
            ),
            Step(L("Solid is what players collide with. Turn it off to walk through a part."),
                aside: L("A part can be visible and not solid — that is how you make decoration players do not bump into.")
            )
        ]
    ) }

    private static var behaviours: Section { Section(
        title: L("Give parts a job"),
        symbolName: "bolt.badge.automatic",
        summary: L("Behaviour is the no-code half of Ablox: pick one and the part does something when a player touches it."),
        steps: BlockBehavior.allCases.map { behaviour in
            Step(L("{} — {}", behaviour.displayName, behaviour.guidance))
        }
    ) }

    private static var gimmicks: Section { Section(
        title: L("Tune the gimmicks"),
        symbolName: "slider.horizontal.3",
        summary: L("Bouncy, Disappearing and Teleporter each get their own settings under the behaviour picker."),
        steps: [
            Step(L("Bouncy: launch speed, in metres per second, from 6 to 30. It starts at 14."),
                aside: L("Speed replaces upward motion rather than adding to it, so bouncing while already rising cannot compound into an escape from the map.")
            ),
            Step(L("Disappearing: how long before it goes, and how long until it comes back.")),
            Step(L("Teleporter: the part it sends players to. A pad cannot target itself."),
                aside: L("Two pads pointing at each other make a two-way door. Pointing a pad at itself would drop the player back on the pad forever, so Studio does not offer it.")
            ),
            Step(L("All three share a cooldown: the wait before the same part can fire again."),
                aside: L("The cooldown is per part and per player. It exists because a player standing on a bounce pad would otherwise be launched every single frame.")
            )
        ]
    ) }

    private static var rules: Section { Section(
        title: L("Add rules"),
        symbolName: "arrow.triangle.branch",
        summary: L("When behaviours are not enough, the Rules tab on the left builds \"when this happens, do that\"."),
        steps: [
            Step(L("A rule is one trigger and any number of actions. Add a rule, pick the trigger, then add actions to it.")),
            Step(L("Triggers include touching or tapping a part, walking near one, the world starting, a repeating timer, and a score being reached.")),
            Step(L("Actions can recolour or move a part, hide it, make it walk-through, teleport the player, award points, show a message, play a sound, or end the round.")),
            Step(L("Give a part the Trigger behaviour when you want it to do nothing on its own and only feed a rule."),
                aside: L("The host decides what a rule does, not the player's iPad. That is why nobody can give themselves points by editing their own copy.")
            )
        ]
    ) }

    private static var testing: Section { Section(
        title: L("Play it"),
        symbolName: "play.circle",
        summary: L("The Play button swaps the editor for the game, in the same world, without leaving Studio."),
        steps: [
            Step(L("Press Play to drop in as a character. Press Stop to go back to editing."),
                aside: L("Entering Play saves the world first, so a crash while testing cannot cost you the session's work.")
            ),
            Step(L("Play from the start every time you add a jump. A gap that looks crossable often is not."),
                aside: L("The editing gestures are switched off in Play mode, so nothing you do as a player can move a part.")
            ),
            Step(L("Watch where you land after touching a hazard — that tells you which checkpoint was actually the last one."))
        ]
    ) }

    private static var together: Section { Section(
        title: L("Build together"),
        symbolName: "person.2",
        summary: L("Two iPads on the same Wi-Fi can edit one world at the same time."),
        steps: [
            Step(L("Tap Share. Studio shows a room code and starts advertising on the local network.")),
            Step(L("On the other iPad, find the session in the list and enter the same code.")),
            Step(L("Edits flow both ways as you make them."),
                aside: L("Joining replaces the joiner's world with the host's, including their undo history — so join before you start building, not after.")
            ),
            Step(L("Everything stays on your network. Nothing is uploaded anywhere."))
        ]
    ) }

    private static var finishing: Section { Section(
        title: L("Before you share it"),
        symbolName: "checkmark.seal",
        summary: L("A short list that catches most of what makes a map unplayable."),
        steps: [
            Step(L("At least one Spawn part. Without it players have nowhere to start."),
                aside: L("Studio flags this for you — a world with no spawn point is reported as a problem before a session starts.")
            ),
            Step(L("A checkpoint before anything that can kill, or a mistake costs the whole run.")),
            Step(L("No part scaled to zero on any axis. It becomes invisible but still blocks players.")),
            Step(L("Walk the whole route in Play mode once, start to finish, without using the editor.")),
            Step(L("Give the world a name you will recognise in the list a month from now."))
        ]
    ) }

    // MARK: - Rendering

    /// The guide as a Markdown document — the source of `docs/making-maps.md`.
    public static var markdown: String {
        var lines: [String] = [
            L("# Making a map in Ablox Studio"),
            "",
            "<!--",
            "  Generated from EditorCore/MapGuide.swift, which is also what Studio's",
            "  in-app guide displays. Edit that file, not this one:",
            "  MapGuideTests fails when the two disagree.",
            "-->",
            "",
            L("Studio shows this same guide in the app — the ? button in the toolbar."),
            ""
        ]

        for (index, section) in sections.enumerated() {
            lines.append("## \(index + 1). \(section.title)")
            lines.append("")
            lines.append(section.summary)
            lines.append("")
            for step in section.steps {
                lines.append("- \(step.text)")
                if let aside = step.aside {
                    lines.append("  - *\(aside)*")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
