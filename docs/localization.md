# English and Japanese

Both apps can be shown in either language. The setting is in the client's
**Settings → Language**, and in Studio behind the **globe** button on the
project list. Three options: **Match the iPad**, **English**, **日本語**.

The two apps share the `ablox.language` key in `UserDefaults`, so setting the
language in one sets it in the other on the same iPad.

## No resource bundle

The usual way — `.lproj` folders and `NSLocalizedString` — needs the target to
declare resources, which means editing the Swift Playgrounds app manifest. That
is the one file in this project that cannot be compiled anywhere but on an
iPad, and it has already cost four round-trips (see [`ipad-build.md`](ipad-build.md)).
It would also put the translations somewhere `swift test` on Linux cannot read
them.

So the translations are a plain Swift table in `AbloxCore/Strings.swift`, which
compiles in the portable core. That is what makes them testable:

| Checked by | What it catches |
|---|---|
| `LocalizationTests` | a key defined twice, an empty translation, a row still in English, placeholders that disagree between the two languages, and any enum `displayName` that has no Japanese |
| `scripts/check-translations.py` | user-facing text never wrapped in `L(...)`, and `L("…")` with no row in the table |
| `MapGuideTests` | the whole map-making guide, sentence by sentence, in both languages |

The first of those found a duplicate key on its first run. A duplicate in a
dictionary *literal* is a runtime crash, which is why the table is an array of
pairs built with `uniquingKeysWith` — a repeat is a failing test rather than a
crash on someone's iPad.

## The English string is the key

```swift
Text(L("Play"))                                  // "Play" / "プレイ"
Text(L("Hosted by {}", peer.hostName))           // "Hosted by Mika" / "ホスト: Mika"
```

`L("Play")`, not `L(.playButton)`. There is no key vocabulary to invent and keep
in step, untranslated call sites are findable by eye, and a missing translation
degrades to readable English instead of a raw identifier on screen. That
fallback is deliberate: a screen with one English line is unpolished, a screen
with `playButton` on it is a bug report.

`{}` rather than `%@`, because `String(format:)` treats `%@` differently on
Linux than on Apple platforms and this has to behave identically in the tests
and on the iPad. It also lets a test check that a translation kept the same
number of holes as its original.

## Switching at runtime

`L(...)` reads a global, `Localization.language`. A global rather than an
environment value, because otherwise every one of the ~280 call sites would
need to reach an `@Environment` — including the ones in the portable core,
which has no SwiftUI at all.

SwiftUI does not observe that global, so nothing would redraw on its own. Both
apps hang `.id(settings.language)` on the view *below* their state objects:
changing the language rebuilds the interface once, while the session, the open
project, the wallet and the undo history survive it. It resets view-local state
such as the open tab, which is acceptable for something that happens rarely and
is arguably wanted.

One consequence worth knowing: anything built with `static let` freezes the
language at first access. `MapGuide`'s sections are `static var` computed
properties for exactly this reason.

## What is *not* translated

- **`rawValue` on any enum.** It is the wire format and the save format. A
  world saved on a Japanese iPad has to open on an English one, and two iPads
  have to agree over the network. `LocalizationTests` asserts this.
- **The brand.** "Ablox" and "ABLOX" stay as they are.
- **Units and example values** — `0.5 m`, `15°`, the `ABC DEF` room-code
  placeholder. Translating them would mean table rows that translate to
  themselves.
- **Player-authored text** — world names, part names, tags, chat.

## Adding a string

1. Write it wrapped: `Text(L("Something new"))`.
2. Add the row to `AbloxCore/Strings.swift`.
3. Run `scripts/check-playgrounds-project.sh`, which runs the translation
   check too.

Step 2 is not optional — CI fails without it. If a string genuinely reads the
same in both languages, add it to `LANGUAGE_NEUTRAL` in
`scripts/check-translations.py` instead, and say why.

`AbloxCore/Strings.swift` is mirrored between the two repositories, so it holds
both apps' strings. Splitting it would mean deciding, for each string, which
half it belongs to — and getting that wrong shows up as a screen in the wrong
language. The entries only one app uses cost a few kilobytes.
