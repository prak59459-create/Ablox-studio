// swift-tools-version: 5.9

// This is the shipping editor. Open `AbloxStudio.swiftpm` in Swift Playgrounds
// on iPad (or in Xcode) and press Run.
//
// The repository root also has a Package.swift, which exists only to build and
// unit-test the portable layers off-device. It points at these same sources.
//
// `AbloxCore` and `Net` are mirrored from the Ablox client repository — run
// `scripts/sync-core.sh --check` to confirm they have not drifted.

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
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .hammer),
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
                    bonjourServices: ["_ablox._tcp"]
                )
            ]
        )
    ],
    targets: [
        .target(
            name: "AbloxCore",
            path: "Sources/AbloxCore"
        ),
        .target(
            name: "EditorCore",
            dependencies: ["AbloxCore"],
            path: "Sources/EditorCore"
        ),
        .executableTarget(
            name: "AbloxStudioApp",
            dependencies: ["AbloxCore", "EditorCore"],
            path: "Sources",
            exclude: ["AbloxCore", "EditorCore"]
        )
    ]
)
