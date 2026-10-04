// swift-tools-version: 5.9

// This is the shipping editor. Open `AbloxStudio.swiftpm` in Swift Playgrounds
// on iPad (or in Xcode) and press Run.
//
// The repository root also has a Package.swift, which exists only to build and
// unit-test the portable layers off-device. It points at these same sources.
//
// `AbloxCore`, `Net` and `Engine` are mirrored from the Ablox client
// repository — run `scripts/sync-core.sh --check` to confirm they have not
// drifted.
//
// One target, as in the client: the whole editor, the mirrored core and
// Studio's own EditorCore included, is one module. The root package builds
// the core and EditorCore on their own as `AbloxCore` for the tests, so no
// file under Sources/ imports it or names a module.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "AbloxStudio",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Ablox Studio",
            targets: ["AbloxStudioApp"],
            bundleIdentifier: "com.ablox.studio",
            teamIdentifier: "",
            displayVersion: "4.0",
            bundleVersion: "31",
            // No `appIcon:` on purpose, matching the client: the parameter is
            // optional, and a wrong `PlaceholderIcon` member name stops the
            // manifest compiling rather than falling back to a default icon.
            // The inverted Studio mark is in `design/AppIcon.png`; set it from
            // Swift Playgrounds' own app-settings screen, which writes the
            // asset catalogue itself.
            accentColor: .presetColor(.cyan),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                // Required on iOS 14+ before Bonjour browsing or any local
                // connection is permitted. Without the declared service type,
                // NWBrowser fails with a policy-denied DNS error rather than
                // simply finding nothing.
                .localNetwork(
                    purposeString: "Ablox Studio finds nearby iPads so you can build a world together. Nothing leaves your local network.",
                    bonjourServiceTypes: ["_ablox._tcp"]
                )
            ]
        )
    ],
    targets: [
        // One module, for the build after an update: the compiler then
        // follows which file uses which declaration, and an update that
        // touches a few files rebuilds those and the files that use what
        // they declare. Across two modules it could only tell that the core
        // had changed, and rebuilt nearly every panel for any new
        // declaration in it (the client's docs/ipad-build.md, "One module
        // again").
        //
        // The target's name must differ from the app product's; Swift
        // Playgrounds refuses a target and a product that share one.
        //
        // `-gnone`: no debug information. Nothing on an iPad reads it, and
        // making it was about a fifth of the build (docs/ipad-build.md). It
        // goes to the compiler itself (`-Xfrontend`): package flags come
        // before the `-g` of a debug build, so given to the driver it would
        // lose, and the last one wins.
        .executableTarget(
            name: "AbloxStudioApp",
            path: "Sources",
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-gnone"])]
        )
    ]
)
