# Published games

Ablox has a **Games** tab: worlds other people have made, with covers, that you
download and play. There is no server behind it.

The list is `index.json` in a public GitHub repository, and a game is a world
file next to it. The app reads those over HTTPS and nothing else. That gives a
catalogue the three things one actually needs — somewhere to put files, a way
for other people to add to it, and a URL — for nothing, and it keeps the
property that matters: **the app only ever reads**. No account, no login, no
upload endpoint to secure.

Publishing is a pull request, which is also the review step an upload form
would not have had.

```
Ablox Studio ──▶ three files ──▶ pull request ──▶ index.json ──▶ Games tab
```

## Setting it up

`catalogue-template/` in this repository is the repository to create. Copy it
into a new public repo, then point the app at it in **Settings → Game list**
(`owner/repo`). The app ships expecting `prak59459-create/ablox-games`.

The setting exists so a school or a club can run its own list.

## Everything downloaded is untrusted

This is the first part of Ablox that reads bytes written by someone who is not
the person holding the iPad, and a listing is a set of *claims*: a path it
wants joined to a URL and to a folder in the app's cache, a size, a name.

The rules live in `AbloxCore/GameCatalogue.swift`, in the portable core, so
they are tested rather than trusted:

| Refused | Because |
|---|---|
| `../` anywhere in a path | joined to the cache directory, it writes outside the sandbox |
| a leading `/` or `~` | absolute — it replaces the base path entirely |
| any `:` in a path | `https:`, `file:` and `data:` all point somewhere else |
| a leading `.` in a component | `.git/config` is a real path in every repository |
| the wrong extension | stops a cover slot being used to fetch something else |
| an id that is not lowercase ASCII | it becomes a folder name, and an iPad's filesystem is case-insensitive, so `Temple` and `temple` would silently be the same download |
| an index over 2 MB, a world over 8 MB, a cover over 4 MB | checked on the bytes, before parsing |
| a world over 5000 parts | more than the renderer can hold at a usable frame rate |

`GameCatalogueTests` asserts each of these against the spellings that would
otherwise work. Deleting the path check makes 22 of them fail.

**One bad listing does not throw away the catalogue.** A repository anyone can
open a pull request against will contain a typo eventually, and hiding nine
hundred working games because of it would be the wrong trade — bad entries are
dropped and the rest are kept.

## Offline

The cache is what is *shown*; a refresh updates it. A failed refresh leaves the
last good list on screen with a quiet note rather than an error, because an
iPad in a classroom is offline more often than not and an empty list looks like
the feature is broken. A game already downloaded plays with no network at all.

## Covers

Drawn from the world rather than asked for — `EditorCore/CoverArtwork.swift` in
Studio. Every published game gets a picture, it is always of the actual world,
and it never goes stale.

It is a plan view: looking straight down, lowest first, with spawn, goal,
checkpoints, hazards and collectibles ringed. Not a render — a perspective shot
of a world with no lighting set up looks worse than an honest diagram, and a
diagram reads at the size a card is actually shown.

The layout is in the portable core and tested, because "the world mapped to one
pixel" and "half of it is off the card" both still produce a PNG.

---

# Making a map with an assistant

Studio's project list has **Make with AI**. It writes a prompt; you paste it
into whichever assistant you use and paste the answer back.

**The app does not talk to a model.** Ablox has no server, no account and no
key, and its own Settings screen tells people what leaves their iPad. Wiring in
a cloud model would contradict that, and it would put a bill and an API key
between a child and a level. You carry the text across yourself.

## Why it works rather than being a novelty

Two things, and both are in the portable core:

**The prompt is generated, not written.** Every list in it comes from
`allCases` at the moment it is built, and the physics numbers come from
`MovementConfig`. A prompt that named a part the palette does not have would
produce a level that fails to import; a prompt that said "you can jump 2 m"
would produce a level nobody can finish. Neither can happen if the prompt
cannot be written by hand.

The jump figures are the interesting part:

```
jumpSpeed 6.0, gravity −18.0  →  a jump rises exactly 1.00 m
                              →  a running jump crosses about 6.0 m
```

`ReachabilityTests` checks those against the simulation itself — the real
`CharacterSolver`, stepped at 120 Hz. If someone retunes the jump, the prompt
changes with it rather than quietly describing a player who no longer exists.

**The answer is checked, field by field.** An assistant is asked for a
`MapPlan` — a flat list of parts using the same words the palette uses — not a
`WorldDocument`. It never writes a UUID or a quaternion, and every value it
does write is checked against something that already exists. An invented part
name is caught *by name*:

> “castle” is not a part. Use one of: block, platform, pillar, ramp, orb,
> hazard, checkpoint, goal, spawn

Every problem is reported at once, not the first, and phrased so the whole list
can be pasted straight back into the conversation that produced it. There is a
**Copy what to fix** button that does exactly that.

## What it copes with

| | |
|---|---|
| a ```` ```json ```` fence | stripped |
| a sentence before or after the JSON | ignored — the object is found by brace matching, so a nested `{}` does not truncate it |
| `"x": "0"` | "numbers must not be in quotes" |
| a missing spawn point | one is added at the centre, and it says so |
| 10 000 parts, or a part at x = 9000 | refused before anything is built |

## What it does not do

It does not check that the level is *finishable*. The prompt tells the
assistant how far a player can jump, and the importer refuses geometry that is
nonsense, but nothing walks the route. Play it before you publish it — the
guide's last section is a list for exactly that.
