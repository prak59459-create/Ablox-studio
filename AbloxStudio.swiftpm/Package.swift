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
// Two targets, as in the client: AbloxCore (the mirrored core and Studio's own
// EditorCore, one module, also built and tested off-device by the root
// package) and the app. Every file outside those two folders says
// `import AbloxCore`.

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
            displayVersion: "2.6",
            bundleVersion: "17",
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
        // Two modules rather than one, for the build on an iPad: each compile
        // job then holds only its own module's source, with the other one read
        // back as a small compiled summary. One module of this size had the
        // compiler holding the whole editor in every job at once, which is
        // what ran an older iPad out of memory and made a build take minutes.
        //
        // The library target's name must differ from the app product's;
        // Swift Playgrounds refuses a target and a product that share one.
        //
        // `-gnone`: no debug information. Nothing on an iPad reads it, and
        // making it was about a fifth of the build (docs/ipad-build.md). It
        // goes to the compiler itself (`-Xfrontend`): package flags come
        // before the `-g` of a debug build, so given to the driver it would
        // lose, and the last one wins.
        .target(
            name: "AbloxCore",
            path: "Sources",
            sources: ["AbloxCore", "EditorCore"],
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-gnone"])]
        ),
        .executableTarget(
            name: "AbloxStudioApp",
            dependencies: ["AbloxCore"],
            path: "Sources",
            exclude: ["AbloxCore", "EditorCore"],
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-gnone"])]
        )
    ]
)
