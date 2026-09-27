# What only the iPad can tell us

Two parts of this project cannot be compiled anywhere except on device:

- **`AbloxStudio.swiftpm/Package.swift`**, because it imports `AppleProductTypes`,
  a module that ships only inside Swift Playgrounds and Xcode; and
- **everything under `Sources/` that touches SwiftUI, RealityKit or Network**,
  because that needs the iOS SDK.

CI builds and tests `AbloxCore` on Linux and parses every file for syntax.
Neither of those sees an argument label that does not exist, or an API that
arrived in a later iOS. So every mistake in those two areas has had to be found
by the person holding the iPad, one round-trip at a time.

This page records what a real device has said, so the same mistake cannot cost
a second round-trip. **Nothing here is recalled from documentation — every line
is something the compiler on the iPad either accepted or rejected.**

---

## Round 1 — the manifest would not evaluate

```
読み込めませんでした。エラーが起きたため、読み込みに失敗しました。
FailedToEvaluateManifest(description: "Mach-O ファイルを生成できなかったため、
ビルドできませんでした。")
```

A mistake in the manifest is not a warning and not a missing feature: the
manifest fails to compile, and Swift Playgrounds refuses to open the project at
all — so none of the source is ever reached.

| Written | Compiler said | Correct form |
|---|---|---|
| `.localNetwork(purposeString:bonjourServices:)` | no such argument label | `bonjourServiceTypes:` |
| `appIcon: .placeholder(icon: .hammer)` | `PlaceholderIcon` has no member `hammer` | omit `appIcon:` |
| `appIcon: .placeholder(icon: .cube)` | `PlaceholderIcon` has no member `cube` | omit `appIcon:` |
| `.portrait(upsideDown: false)` | cannot call value of non-function type `InterfaceOrientation` | `.portrait` |

**`appIcon:` is omitted deliberately.** The parameter is optional. Two
independent guesses at `PlaceholderIcon`'s vocabulary were both wrong, and there
is no way to enumerate the real one from here — so the safest icon is no icon.
The inverted Studio mark lives in `design/AppIcon.png`; set it from Swift
Playgrounds' own app-settings screen (the palette button in the toolbar), which
writes a valid asset catalogue itself. Hand-writing one is another manifest
error waiting to happen.

**`InterfaceOrientation` values are properties, not functions.** The error
wording is the useful part: *"cannot call value of non-function type"* means
`portrait` resolved fine and simply is not callable. Upside-down portrait is
expressed by leaving it out of the array, not by an argument.

### Accepted

These appeared in a manifest whose only reported errors were the two above. The
Swift type-checker reports every bad argument in a call, so the rest of that
call type-checked:

- `import AppleProductTypes`
- `.iOSApplication(name:targets:bundleIdentifier:teamIdentifier:displayVersion:bundleVersion:appIcon:accentColor:supportedDeviceFamilies:supportedInterfaceOrientations:capabilities:)`
- `accentColor: .presetColor(.cyan)`
- `supportedDeviceFamilies: [.pad]` (the client also uses `.phone`)
- `supportedInterfaceOrientations: [.landscapeRight, .landscapeLeft]`
- `capabilities: [.localNetwork(purposeString:bonjourServiceTypes:)]`
- `platforms: [.iOS("17.0")]`
- `targets: [.executableTarget(name:path:)]`

---

## Round 2 — the source compiled for the first time

With the manifest healthy, Swift Playgrounds reached the app's own code and
reported three separate problems. They were found in the Ablox client, which
is opened more often; the shared layers here are byte-identical copies, so
every one of them applied to this project too.

### `Cannot find 'AbloxCore' in scope`

`ColorRGBA.lerp` called the free `lerp(_:_:_:)` from `Math.swift` as
`AbloxCore.lerp(...)`. Inside a type that has its own static `lerp`, the free
function can only be reached by naming its module — and **this module has two
names**:

| Build | Module name |
|---|---|
| Swift Playgrounds on device | `AbloxStudioApp` here, `AbloxApp` in the client |
| The root test package | `AbloxCore` |

Hard-coding either breaks the other, and only the iPad can report the one it
breaks. The fix is to depend on neither: the four lines of arithmetic are
written out inline.

The same trap is why, at the time, **no file under `Sources/` contained
`import AbloxCore`**: on device there was one module and nothing to import.
That changed with *Two targets* below — the core is now a module called
`AbloxCore` in both builds, and every file outside it imports it.

### `is only available in iOS 18.0 or newer`

`MeshResource.generateCylinder(height:radius:)` and
`generateCone(height:radius:)` are iOS 18 API. The deployment target is iOS 17,
so they do not compile.

The two honest options were raising the deployment target — dropping every iPad
that stopped at iPadOS 17 — or building the meshes. `MeshResource.generate(from:)`
has taken hand-built `MeshDescriptor`s since iOS 15, so
`AbloxCore/MeshGeometry.swift` generates the vertices and
`Engine/ProceduralMesh.swift` hands them over, behind `.abloxCylinder` /
`.abloxCone`.

Putting the vertices in `AbloxCore` is the point: that module compiles on Linux,
so winding direction, normal direction, index bounds and silhouette size are
asserted in `MeshGeometryTests` rather than discovered on a screen. A
backwards-wound triangle is *invisible from one side*, not obviously broken,
which is exactly the kind of defect that survives a visual check.

There is deliberately no `if #available(iOS 18, *)` branch calling Apple's
version. One path means the geometry everyone sees is the geometry the tests
cover; a second path would only ever run on the iPads least likely to be around
to report a problem with it.

### `Switch must be exhaustive`

`WorldScene.apply(effect:)` listed the actions it ignores by name, and Task 4
added `EventAction.bouncePlayer` without updating it. This is the compiler doing
its job — the case list stays spelled out rather than becoming a `default:`,
precisely so the next added action forces the decision again.

---

## Round 3 — six minutes, "build failed", and no error

Reported from the Ablox client; the shared layers here are the same files.

On an iPad (9th generation, 3 GB of memory) the first build after an update
took about six minutes and stopped with a failed build that listed no error.
The third attempt launched, about eighteen minutes in all. Nothing in the
source was wrong — the same code builds for the iOS simulator on CI — so the
reading here is that the build ran out of memory. As one module of about
46,000 lines, every compile job held the whole app.

The same round's screen listed these, fixed at the time:

| Written | Compiler said | Correct form |
|---|---|---|
| `some Gesture` in a view | A 'some' type must specify only 'Any', 'AnyObject', protocols, and/or a base class | `AbloxCore` has a `Gesture` of its own, which hides SwiftUI's: `some SwiftUI.Gesture` |
| a generic function nested in a view method, reading `settings.wallet` | Main actor-isolated property 'wallet' can not be referenced from a nonisolated context | read it into a local first |
| `.onChange(of:perform:)` | deprecated in iOS 17 | the two-parameter closure |
| a captured `var resumed` in a continuation | mutation of captured var in concurrently-executing code (warning) | a small class with a lock |

---

## Two targets

Both apps now declare two targets: the library `AbloxCore` (here the
mirrored `Sources/AbloxCore` and Studio's own `Sources/EditorCore`),
and the app, which depends on it. Each compile job then holds one module's
source, with the other read back as a small compiled summary, instead of the
whole app at once.

What CI measured, building for the iOS simulator on a 3-core `macos-15`
runner (timing instrumentation on, so the figures run high):

| Ablox | Build | Swift compiling, summed | Core interface |
|---|---|---|---|
| two targets, core still importing SwiftUI and RealityKit | 140 s | 204 s | 24 s |
| two targets, core importing Foundation alone | 95 s | 116 s | 5.6 s |

The second row is the point of the rules below: every compile job of a module
loads whatever any of its files imports, and the app side waits for the core's
interface before it can start.

Most of a first build is not the app at all but the system's own modules
(UIKit, SwiftUI, RealityKit) being prepared, which a device does once and
keeps. Measured in one job, so the runner's speed is the same throughout:

| Ablox, one after another on one runner | Build |
|---|---|
| first build, system modules not yet prepared | 77 s |
| again from clean, modules already prepared | 34–40 s |
| the same, without debug information | 28–31 s |

`scripts/ios-build-compare.sh` makes that table for any build setting, and
`PER_FILE=1 scripts/ios-build-times.sh` lists what each file costs, split
into type checking, SILGen, IRGen and the rest. SwiftUI screens turn into
about five times as much code per line as the core's logic, so the cost is
spread over every view rather than a few slow functions.

- **The core imports Foundation alone** (and `Compression`). Glue to Apple
  frameworks lives in `Engine/AppleBridging.swift`.
- **Every file outside the core says `import AbloxCore`.**
- **Names the core shares with Apple frameworks** — `Gesture`, `BoundingBox`,
  `MusicTrack` — are pinned to the core's in `Engine/CoreNames.swift`, so the
  app's files mean what they meant as one module.
- **What the app uses from the core is `public`.** An internal member used
  from the app is a compile error on device, not on Linux, so the macOS CI
  build (`.github/workflows/ios-build.yml`) is what catches it.
- **The library target's name differs from the app product's.**
- **No macros** (`#Preview`, `@Observable`, …). Each needs a plugin run
  during the build, for nothing a player sees.
- **No debug information**: both targets pass `-gnone` through
  `unsafeFlags`, worth the difference between the last two rows above.
  Nothing on an iPad reads debug information. **Not yet seen on device**:
  if Swift Playgrounds refuses the manifest over `unsafeFlags`, its exact
  words go on this page and the two `swiftSettings` lines come out.

**Seen on device.** The two-target Ablox project opened in Swift Playgrounds
on the iPad. (Studio has the same layout; its own round-trip is still to
come.)

The module boundary the tests need still comes from the **root**
`Package.swift`, which points at the same folders and compiles them as
`AbloxCore`.

SwiftPM dependencies are still avoided. Swift Playgrounds can only resolve them
by git URL, which would mean the project cannot be opened without a network.
The shared core is mirrored between the two repositories as files, and
`scripts/sync-core.sh --check` keeps the copies byte-identical.

---

## Guard

`scripts/check-playgrounds-project.sh` runs in CI. It cannot type-check the
manifest or the Apple layers — nothing here can. All it does is refuse the
spellings this page records as rejected, plus assert the two-target shape, the
`AppleProductTypes` import, `import AbloxCore` outside the core, a core that
imports Foundation alone, and no macros.

It is a ratchet on known mistakes, not a substitute for opening the project on
an iPad. **When a new error turns up on device, add its exact wording to this
page and a rule to that script**, so it can only ever cost one round-trip.
