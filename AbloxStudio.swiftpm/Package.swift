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
// Deliberately ONE target, matching the client. Swift Playgrounds App projects
// are built as a single module; the off-device test package supplies the
// module boundary instead, which is why no file in Sources/ imports AbloxCore.

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
            displayVersion: "1.1",
            bundleVersion: "2",
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
        .executableTarget(
            name: "AbloxStudioApp",
            path: "Sources"
        )
    ]
)
