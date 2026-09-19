# Making a map in Ablox Studio

<!--
  Generated from EditorCore/MapGuide.swift, which is also what Studio's
  in-app guide displays. Edit that file, not this one:
  MapGuideTests fails when the two disagree.
-->

Studio shows this same guide in the app — the ? button in the toolbar.

## 1. Start a world

Every map is one world file. Studio keeps them for you and saves as you work.

- From the project list, tap the new-project button, name the world, and pick a template.
- Obstacle Course starts you with a floor, a spawn pad, stairs, a coin and a finish line — it already works if you press Play. Blank gives you a floor and a spawn point.
  - *Starting from Obstacle Course and taking things away is usually faster than starting from Blank, because the pieces are already wired up for you to copy.*
- Build on the grid you land on. It is the floor, and it is not a block — you cannot select or delete it.
- There is no Save button. Studio saves shortly after you stop editing, when you press Play, and when you go back to the project list.
  - *The dot beside the world's name in the toolbar means there are changes not yet written. Saving is delayed on purpose: dragging a part makes an edit every frame, and writing all of them to storage would wear it out for no benefit.*

## 2. Put parts in

The palette along the bottom of the viewport is where every part comes from.

- Tap a part in the palette and it lands in front of the camera.
  - *It is placed where you are looking at the moment you tap, not at the world origin — so aim first, then tap.*
- The new part is selected straight away, so the Inspector on the right is already showing it.
- Tap the chevron above the palette to fold it away when you need the room.
  - *Parts land on the grid, so two of the same kind placed side by side line up exactly.*

## 3. Move, turn, resize

Four tools in the toolbar. Pick one, then drag the part.

- Select picks parts. Tap a part to select it; tap with two fingers to add it to the selection instead of replacing it.
  - *Nothing is selectable in Play mode — the editing gestures are switched off there entirely.*
- Move, Rotate and Scale each drag the selected parts along the ground or around their centre.
- The grid button snaps position to 0.25, 0.5, 1 or 2 metres. The angle button snaps rotation to 15°, 45° or 90°. Both have an Off setting.
  - *Off is for fine adjustment only — platforms that do not line up on the grid leave gaps a player can fall through.*
- Undo and Redo go back through everything, including deletes.
- Duplicate and Delete are in the Inspector's Actions group, and in the menu you get by pressing and holding a row in the Explorer list.
  - *Duplicating a group copies its children and keeps their internal parent links, so copying a whole staircase gives you a staircase, not nine loose steps.*
- In the Explorer, drag one row onto another to make it a child. Moving the parent then moves the child with it.
  - *Group the parts you will want to copy or move as a unit before you build the second one — that is what turns one staircase into a tower.*

## 4. Make it look right

The Inspector on the right edits whatever is selected.

- Name each part as you go. The Explorer list and every rule refer to parts by name.
- Colour and material change how a part is lit. Neon glows without needing a light; glass is see-through.
- Anchored keeps a part still. Turn it off and the part falls in Play mode.
  - *Almost everything you build should stay anchored. Unanchored parts are for the one crate you meant to knock over.*
- Solid is what players collide with. Turn it off to walk through a part.
  - *A part can be visible and not solid — that is how you make decoration players do not bump into.*

## 5. Give parts a job

Behaviour is the no-code half of Ablox: pick one and the part does something when a player touches it.

- None — Ordinary scenery. Players can stand on it and nothing else happens.
- Spawn Point — Players start on top of this block.
- Checkpoint — Touching it sets where the player respawns. Players walk through it.
- Hazard — Touching it sends the player back to their last checkpoint.
- Collectible — Each player can collect it once. Players walk through it.
- Goal — Touching it ends the round for everyone.
- Trigger — Does nothing by itself — add a rule that listens for it.
- Bouncy — Launches anyone who lands on it. A trampoline.
- Disappearing — Vanishes shortly after it is stepped on, then comes back.
- Teleporter — Moves the player to another block. Players walk through it.

## 6. Tune the gimmicks

Bouncy, Disappearing and Teleporter each get their own settings under the behaviour picker.

- Bouncy: launch speed, in metres per second, from 6 to 30. It starts at 14.
  - *Speed replaces upward motion rather than adding to it, so bouncing while already rising cannot compound into an escape from the map.*
- Disappearing: how long before it goes, and how long until it comes back.
- Teleporter: the part it sends players to. A pad cannot target itself.
  - *Two pads pointing at each other make a two-way door. Pointing a pad at itself would drop the player back on the pad forever, so Studio does not offer it.*
- All three share a cooldown: the wait before the same part can fire again.
  - *The cooldown is per part and per player. It exists because a player standing on a bounce pad would otherwise be launched every single frame.*

## 7. Add rules

When behaviours are not enough, the Rules tab on the left builds "when this happens, do that".

- A rule is one trigger and any number of actions. Add a rule, pick the trigger, then add actions to it.
- Triggers include touching or tapping a part, walking near one, the world starting, a repeating timer, and a score being reached.
- Actions can recolour or move a part, hide it, make it walk-through, teleport the player, award points, show a message, play a sound, or end the round.
- Give a part the Trigger behaviour when you want it to do nothing on its own and only feed a rule.
  - *The host decides what a rule does, not the player's iPad. That is why nobody can give themselves points by editing their own copy.*

## 8. Play it

The Play button swaps the editor for the game, in the same world, without leaving Studio.

- Press Play to drop in as a character. Press Stop to go back to editing.
  - *Entering Play saves the world first, so a crash while testing cannot cost you the session's work.*
- Play from the start every time you add a jump. A gap that looks crossable often is not.
  - *The editing gestures are switched off in Play mode, so nothing you do as a player can move a part.*
- Watch where you land after touching a hazard — that tells you which checkpoint was actually the last one.

## 9. Build together

Two iPads on the same Wi-Fi can edit one world at the same time.

- Tap Share. Studio shows a room code and starts advertising on the local network.
- On the other iPad, find the session in the list and enter the same code.
- Edits flow both ways as you make them.
  - *Joining replaces the joiner's world with the host's, including their undo history — so join before you start building, not after.*
- Everything stays on your network. Nothing is uploaded anywhere.

## 10. Before you share it

A short list that catches most of what makes a map unplayable.

- At least one Spawn part. Without it players have nowhere to start.
  - *Studio flags this for you — a world with no spawn point is reported as a problem before a session starts.*
- A checkpoint before anything that can kill, or a mistake costs the whole run.
- No part scaled to zero on any axis. It becomes invisible but still blocks players.
- Walk the whole route in Play mode once, start to finish, without using the editor.
- Give the world a name you will recognise in the list a month from now.
