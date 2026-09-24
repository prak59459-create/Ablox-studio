# Using the editor

## Layout

```
┌──────────────────────────────────────────────────────────────┐
│ ‹  World name ●   [select|move|rotate|scale]  grid  ↶ ↷  ⤢ ⧉ │
├────────────┬──────────────────────────────┬──────────────────┤
│ Explorer   │                              │ Inspector        │
│ / Rules    │          viewport            │                  │
│            │                              │  transform       │
│  ▸ Floor   │                              │  appearance      │
│  ▾ Course  │                              │  behaviour       │
│    · Step1 │                              │  physics         │
│    · Step2 │   ┌──────────────────────┐   │  tags            │
│  ▸ Coin    │   │  part palette        │   │                  │
│            │   └──────────────────────┘   │                  │
├────────────┤                              │                  │
│ ✓ No problems                             │                  │
└────────────┴──────────────────────────────┴──────────────────┘
```

## Gestures

| Gesture | Does |
|---|---|
| Tap a block | Select it |
| Tap empty space | Deselect |
| Two-finger tap a block | Add to / remove from the selection |
| One-finger drag | Transform the selection with the active tool |
| One-finger drag, nothing selected | Pan the camera |
| Two-finger drag | Orbit the camera |
| Pinch | Zoom |
| Drag a row onto another in Explorer | Reparent |
| Long-press a row | Context menu |

One finger transforms, two fingers move the camera. That separation is the
whole reason a drag on a block never accidentally spins the view — the pan
recogniser is set to `require(toFail:)` the orbit recogniser.

## Tools

**Select** — picking only. Safe to leave on while arranging the camera.

**Move** — drags along the ground plane, mapped through the camera's yaw so
dragging right always moves the block right *on screen*, whichever way you are
facing. Snaps to the grid.

**Rotate** — yaw only. Blocks are boxes; pitch and roll are available in the
Inspector's numeric fields when you actually want them, and are an easy way to
disorient yourself when you don't.

**Scale** — uniform, multiplicative, clamped so a block can never reach zero
size (which would make it invisible and invert its normals).

## Snapping

Grid and angle snapping are each a single value, where `0` means off — rather
than a value plus a separate flag that can disagree with it.

Grid: off, 0.25 m, 0.5 m, 1 m, 2 m. Angle: off, 15°, 45°, 90°.

## Behaviours

Set on a block in the Inspector. These work with **no rule at all** — most
worlds never need to open the rule editor.

| Behaviour | What happens | Solid? |
|---|---|---|
| None | Scenery | yes |
| Spawn | Players start on top of it | yes |
| Checkpoint | Touching it sets where you respawn | walk through |
| Hazard | Touching it sends you back to your checkpoint | yes |
| Collectible | Awards points, once per player, then hides | walk through |
| Goal | Ends the round for everyone | yes |
| Trigger | Nothing on its own — for rules to hang off | walk through |

The "walk through" column matters: a coin you bounced off would be miserable,
and lava you fell through would not be lava.

## Rules

A rule is one trigger and a list of actions. Everything is a picker.

**Triggers**

| Trigger | Fires when |
|---|---|
| A player touches a block | that specific block is touched |
| A player touches any tagged block | any block with the tag is touched |
| A player taps a block | it is tapped in play mode |
| A player comes close | a player is within a radius (measured horizontally, so standing on a tower still counts) |
| The round starts | once, at the start |
| On a timer | every N seconds |
| A score is reached | any player's score passes a threshold |

**Actions**

Change a block's colour · Move a block · Hide a block · Make a block
walk-through · Teleport the player · Award points · Show a message · Play a
sound · End the round.

**Limits.** *Only once* caps a rule at one firing per round. *Wait between* is a
cooldown, which stops a touch rule from firing on every physics tick while
somebody stands on the block.

### Tags

Give ten coins the tag `coin` and one rule covers all of them. Tag matching is
case-insensitive, so `Coin` and `COIN` are the same tag.

### Who decides

Rules are evaluated **on the host only**. Clients report what they observed
("I touched block X") and receive resolved effects ("you gained 10 points").
A client never tells the host what its own score is, so scores stay consistent
across every iPad in the room.

## Scripts

The **Script** tab, beside Explorer and Rules, is for everything the rule
pickers cannot say: shooters, menus and shops, cameras, NPCs, maps that build
and change themselves. A world holds any number of `.absc` files (up to 32):

- **New file**, or tap an example to add it as a file of its own.
- **Import** reads `.absc` files from the Files app — written on a computer,
  sent by a friend. The **…** menu on a file renames it, switches it off
  without deleting it, exports it through the share sheet, or deletes it.
- Tapping a file opens the editor, with **Check** (syntax errors and misspelled
  events across every file, each naming its file and line), **Test run** (plays
  every file for five seconds with two idle players and lists the camera,
  weapon, screen items, NPCs, created blocks, messages and `print` output),
  **Examples** and the **Reference** beside the code.

- **Get .absc files from GitHub** names a public repository, branch and
  folder; **Get the latest now** then pulls every `.absc` in it, replacing
  files with the same name and never deleting one that is only on the iPad.
  A pull is one undo step. With **Get the latest every time the game starts**
  on, the iPad hosting the game pulls again before each round.

A visit to the editor is one undo step. The files are saved in the world,
travel to co-editors as a `scriptsReplaced` delta, and run on whichever iPad
hosts the game in Ablox. The language and API are described in
[Ablox `docs/scripting.md`](https://github.com/prak59459-create/Ablox/blob/main/docs/scripting.md)
(日本語: [`scripting.ja.md`](https://github.com/prak59459-create/Ablox/blob/main/docs/scripting.ja.md)).

## Opening a published game

**Open a published game** on the project screen lists the game list the Games
tab in Ablox reads — the repository and branch are shared with Ablox's
Settings and can be changed in the sheet — and downloads a game, with its map,
rules and `.absc` files, as a new project under a name not already taken.

## Building together

Tap **Share**. Studio starts hosting and shows a six-character room code.
Another iPad running Studio sees the project under *Build together*, types the
code, and joins.

Every edit becomes a `WorldDelta` and is relayed live. Remote edits are applied
without entering your undo history — undoing your friend's change out of your
own stack would be baffling, and would immediately desync the two documents.

The connection is TLS 1.3 with a key derived from the room code. The
[security model](https://github.com/prak59459-create/Ablox/blob/main/docs/networking.md)
is written out plainly in the client repository, limitations included.

## Validation

The Explorer footer continuously reports structural problems: a block pointing
at a parent that no longer exists, a parent cycle, a rule referring to a
deleted block, a zero scale component, or a world with no spawn point. Tap one
to select the block it concerns.

None of these block saving. They are the things that are *legal* in the file
format but will surprise you at play time.

## Saving

Autosave is debounced by three seconds, because a drag produces an edit every
frame and writing the world to disk sixty times a second would thrash flash
storage for nothing. Entering Play mode saves first — a crash while testing
must not lose the work.

The dot beside the world name in the toolbar means there are unsaved changes.

Each world is a single JSON file in Application Support. One file, one world,
readable if you open it.
