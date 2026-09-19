# The Swift Playgrounds app manifest

`AbloxStudio.swiftpm/Package.swift` is the one file in this repository that **cannot
be checked anywhere except on an iPad**. It imports `AppleProductTypes`, which
ships only inside Swift Playgrounds and Xcode — there is no Linux copy, so
`swift build`, CI, and every syntax check here are blind to it.

That matters more than it sounds. A mistake in this file is not a warning and
not a missing feature: the manifest fails to compile, and Swift Playgrounds
refuses to open the project at all.

```
読み込めませんでした。エラーが起きたため、読み込みに失敗しました。
FailedToEvaluateManifest(description: "Mach-O ファイルを生成できなかったため、
ビルドできませんでした。")
```

So this page records what an actual device has said, to stop the same argument
label being guessed a fourth time. **Nothing here is from documentation — every
line is something the compiler on the iPad either accepted or rejected.**

## Rejected on device

| Written | Compiler said | Correct form |
|---|---|---|
| `.localNetwork(purposeString:bonjourServices:)` | no such argument label | `bonjourServiceTypes:` |
| `appIcon: .placeholder(icon: .hammer)` | `PlaceholderIcon` has no member `hammer` | omit `appIcon:` |
| `appIcon: .placeholder(icon: .cube)` | `PlaceholderIcon` has no member `cube` | omit `appIcon:` |
| `.portrait(upsideDown: false)` | cannot call value of non-function type `InterfaceOrientation` | `.portrait` |

Two things follow from that list.

**`appIcon:` is omitted deliberately.** The parameter is optional. Two
independent guesses at `PlaceholderIcon`'s vocabulary were both wrong, and
there is no way to enumerate the real one from here — so the safest icon is no
icon. The inverted Studio mark lives in `design/AppIcon.png`; set it from Swift
Playgrounds' own app-settings screen (the palette button in the toolbar), which
writes a valid asset catalogue itself. Hand-writing one is another manifest
error waiting to happen.

**`InterfaceOrientation` values are properties, not functions.** The error
wording is the useful part: *"cannot call value of non-function type"* means
`portrait` resolved fine and simply is not callable. Upside-down portrait is
expressed by leaving it out of the array, not by an argument.

## Accepted on device

These all appeared in a manifest whose only reported errors were the two above.
The Swift type-checker reports every bad argument in a call, so the rest of that
call type-checked. (The observations come from the Ablox client project, which
is opened more often; the two manifests are deliberately the same shape, so
what the compiler accepts there it accepts here.)

- `import AppleProductTypes`
- `.iOSApplication(name:targets:bundleIdentifier:teamIdentifier:displayVersion:bundleVersion:appIcon:accentColor:supportedDeviceFamilies:supportedInterfaceOrientations:capabilities:)`
- `accentColor: .presetColor(.cyan)`
- `supportedDeviceFamilies: [.pad]` (the client also uses `.phone`)
- `supportedInterfaceOrientations: [.landscapeRight, .landscapeLeft]`
- `capabilities: [.localNetwork(purposeString:bonjourServiceTypes:)]`
- `platforms: [.iOS("17.0")]`
- `targets: [.executableTarget(name:path:)]`

## One target, always

Both apps declare exactly one `.executableTarget`. Swift Playgrounds builds and
navigates an App project as a single module; splitting the sources into library
targets bought nothing on device and added another way for loading to fail.

The module boundary the tests need comes from the **root** `Package.swift`
instead — a separate, ordinary SwiftPM manifest that points at the same source
files and compiles them as `AbloxCore`. That is why no file under
`Sources/` contains `import AbloxCore`: on device there is nothing to import.

SwiftPM dependencies are avoided for the same reason. Swift Playgrounds can only
resolve them by git URL, which would mean the project cannot be opened without a
network. The shared core is mirrored between the two repositories as files, and
`scripts/sync-core.sh --check` keeps the copies byte-identical.

## Guard

`scripts/check-app-manifest.sh` runs in CI. It cannot type-check the manifest —
nothing here can. All it does is refuse any spelling this page records as
rejected, plus assert the single-target shape and the `AppleProductTypes`
import. It is a ratchet on known mistakes, not a substitute for opening the
project on an iPad.

When a new manifest error does turn up on device, add the exact wording to the
table above and a rule to that script, so it can only cost one round-trip.
