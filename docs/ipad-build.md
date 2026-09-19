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

The same trap is why **no file under `Sources/` contains `import AbloxCore`**.
On device there is one module and nothing to import.

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

## One target, always

Both apps declare exactly one `.executableTarget`. Swift Playgrounds builds and
navigates an App project as a single module; splitting the sources into library
targets bought nothing on device and added another way for loading to fail.

The module boundary the tests need comes from the **root** `Package.swift`
instead — an ordinary SwiftPM manifest that points at the same source files and
compiles them as `AbloxCore`.

SwiftPM dependencies are avoided for the same reason. Swift Playgrounds can only
resolve them by git URL, which would mean the project cannot be opened without a
network. The shared core is mirrored between the two repositories as files, and
`scripts/sync-core.sh --check` keeps the copies byte-identical.

---

## Guard

`scripts/check-playgrounds-project.sh` runs in CI. It cannot type-check the
manifest or the Apple layers — nothing here can. All it does is refuse the
spellings this page records as rejected, plus assert the single-target shape and
the `AppleProductTypes` import.

It is a ratchet on known mistakes, not a substitute for opening the project on
an iPad. **When a new error turns up on device, add its exact wording to this
page and a rule to that script**, so it can only ever cost one round-trip.
