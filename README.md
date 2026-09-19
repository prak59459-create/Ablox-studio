# Ablox Studio

The level editor for [Ablox](https://github.com/prak59459-create/Ablox), built
to run in **Swift Playgrounds** on iPad. Place parts, set their properties,
wire up events, and test the world without leaving the app.

| Repository | App | What it does |
|---|---|---|
| [`Ablox`](https://github.com/prak59459-create/Ablox) | `Ablox.swiftpm` | The player client: menu, world library, 3D play, multiplayer |
| **this one** | `AbloxStudio.swiftpm` | The editor |

## Running it

Open `AbloxStudio.swiftpm` in Swift Playgrounds on iPad (iPadOS 17 or later)
and press Run. It also opens in Xcode 15+.

Say yes to the **Local Network** prompt if you want to build with someone else
— without it, Studio cannot see other iPads.

## What it does

**Three-pane editor.** Explorer on the left, viewport in the middle, Inspector
on the right, part palette along the bottom.

**Select / Move / Rotate / Scale**, with grid and angle snapping. One finger
transforms the selection, two fingers orbit the camera, pinch zooms. Splitting
them that way means a drag on a block never accidentally spins the view.

**Explorer tree** with drag-to-reparent. Cycles are refused rather than
corrupting the document.

**Inspector** for transform, colour, shape, material, gameplay behaviour,
physics flags and tags — and, with nothing selected, the world's own lighting,
gravity and fall limit.

**Rule editor.** Triggers and actions are pickers, never typed text. A closed
vocabulary cannot contain a syntax error, which matters when the person
building the world is eleven and the keyboard is covering half the screen.

**Undo/redo** that understands gestures: a sixty-frame drag is one undo step,
not sixty.

**Play mode** runs the world in place, with physics on, so you can test a jump
without leaving the editor.

**Build together.** Tap Share and another iPad running Studio can join over the
same encrypted local mesh the game uses, and edit with you live.

## Two Package.swift files, on purpose

- `AbloxStudio.swiftpm/Package.swift` — the shipping app. This is what you open.
- `Package.swift` (repo root) — builds and tests the portable modules on any
  platform, including Linux CI.

```
swift test        # 453 tests, no device or simulator needed
```

Two modules are portable and therefore tested:

- **`AbloxCore`** — the shared data model, wire format and rule engine. Mirrored
  from the Ablox client; see below.
- **`EditorCore`** — Studio's own: `EditCommand`, `EditHistory` and
  `EditorDocument`. Every editing operation a user can perform goes through
  `EditorDocument`, which has no SwiftUI or RealityKit in it, so all of it is
  directly testable — including the awkward parts, like "deleting a parent and
  its already-selected child must not resurrect duplicates on undo".

## Why the shared code is mirrored, not a dependency

`AbloxCore` and `Net` are byte-identical copies of the canonical versions in
the Ablox client repository.

Swift Playgrounds on iPad can only add package dependencies by git URL, which
means a device needs network access and a resolved checkout before the project
will even open. For an app whose whole premise is "works on an iPad with no
server", making the editor fail to open without internet would be an odd trade.

The mirror is kept honest by a script rather than by discipline:

```
scripts/sync-core.sh           # copy from ../Ablox
scripts/sync-core.sh --check   # fail if anything has drifted
```

CI runs `--check`, so drift fails a build instead of being discovered as a
protocol mismatch between two iPads in a classroom.

## How editing works

Undo is **explicit inverse commands**, not world snapshots. A world with a few
hundred blocks is a sizeable JSON document, and keeping fifty copies of it on an
iPad to support Ctrl-Z would be megabytes of memory. An inverse command is a
handful of bytes.

It also hands the network layer exactly what it needs for free: every
`EditCommand` already knows how to express itself as a `WorldDelta`, which is
what gets broadcast to co-editors. One mechanism, two jobs.

```
EditCommand ──▶ apply(to: &world)     the edit
            ├─▶ inverse               undo
            └─▶ deltas                what peers are told
```

Remote edits go through `applyRemote(_:)`, which deliberately does *not* record
them: undoing someone else's edit out of your own history would be baffling.

## Further reading

- [`docs/making-maps.md`](docs/making-maps.md) — how to build a map, start to finish. Studio shows the same guide in the app, behind the **?** button in the toolbar; both come from `EditorCore/MapGuide.swift`, so edit that and run `scripts/regenerate-docs.sh`
- [`docs/making-maps.ja.md`](docs/making-maps.ja.md) — the same guide in Japanese, from the same source
- [`docs/editor.md`](docs/editor.md) — gestures, tools, and the rule vocabulary
- [`docs/games.md`](docs/games.md) — publishing to the game list, and making a map with an assistant
- [`docs/localization.md`](docs/localization.md) — English and Japanese, and why there is no `.lproj`
- [`docs/ipad-build.md`](docs/ipad-build.md) — the errors only an iPad can report, and what the device has actually said
- [Ablox `docs/networking.md`](https://github.com/prak59459-create/Ablox/blob/main/docs/networking.md) — the protocol and its security model
- [Ablox `docs/architecture.md`](https://github.com/prak59459-create/Ablox/blob/main/docs/architecture.md) — how the layers fit together
