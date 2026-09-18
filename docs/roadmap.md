# Roadmap

Ablox Studio covers **Phase 3** of the brief, plus the edit/play switching from
Phase 4.

## Built

- [x] Three-pane editor: Explorer, viewport, Inspector, part palette
- [x] Select / Move / Rotate / Scale with grid and angle snapping
- [x] Orbit, pan and pinch camera, separated from the transform gesture
- [x] Explorer tree with drag-to-reparent, cycle-safe
- [x] Inspector: transform, colour, shape, material, behaviour, physics, tags
- [x] World settings: lighting, gravity, fall limit, backdrop
- [x] Visual rule editor — pickers only, no typed syntax
- [x] Undo/redo with gesture coalescing
- [x] Live validation of structural problems
- [x] Play mode in place, with physics
- [x] Live co-editing over the same TLS mesh the game uses
- [x] Debounced autosave; one JSON file per world

## Deliberately not built

**On-screen gizmo handles.** Transforms are driven by whole-screen drags with
the active tool rather than by grabbing an arrow. On a 13" iPad a fingertip
covers roughly the area a gizmo arrow occupies at a typical camera distance,
and mis-grabs would be constant. The tool picker makes the axis explicit
instead. Worth revisiting with a hover-capable pointer.

**Rubber-band selection.** Multi-select works by two-finger tapping each block.
A drag-rectangle would collide with the pan gesture, and resolving that needs a
modal "selection mode" that costs more than it gives.

**Nested prefabs.** Blocks parent into a tree, but there is no notion of a
reusable component that updates all its instances. It is a real feature, not a
small one, and nothing in the brief needs it.

**Texture and model import.** Every visual is a RealityKit primitive with a
colour. A Playground should be readable Swift, not a bundle of binaries.

## Known rough edges

- Joining a co-editing session replaces your document wholesale, undo history
  included. That is correct — the history described a document that is no
  longer on screen — but it is abrupt if you had unsaved local work.
- Two people dragging the *same* block at once is last-writer-wins. Fine for
  the two-or-three-people case this is built for; a real CRDT would be a
  different project.
- The rule editor lets you point an action at a deleted block. It is shown as
  `(deleted)` rather than silently repointed, and `validate()` reports it, but
  it is not prevented.

## If work continued

1. A gizmo for pointer-equipped iPads, keeping the current gestures for touch.
2. Per-block "notes", so a shared world can explain itself to a collaborator.
3. Prefabs, once there is a world big enough to need them.
