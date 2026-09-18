// swift-tools-version: 5.9
import PackageDescription

// As in the Ablox client repository, this manifest exists so the portable
// layers can be built and unit-tested off-device, including on Linux CI.
// It points at the same sources the iPad app compiles.
//
// The shipping app is `AbloxStudio.swiftpm` — that is what you open in Swift
// Playgrounds, and it is a single target, because that is the layout Swift
// Playgrounds expects.
//
// The module boundary lives here instead. `AbloxCore` below covers both the
// mirrored core and Studio's own `EditorCore`, compiled together as one
// module. That is what lets the app stay single-target while these sources
// stay testable: no file has to say `import AbloxCore`, so the same files work
// under both manifests.
//
// The core sources are a mirror of the Ablox client's; run
// `scripts/sync-core.sh --check` to confirm they have not drifted.
let package = Package(
    name: "AbloxStudioCore",
    products: [
        .library(name: "AbloxCore", targets: ["AbloxCore"])
    ],
    targets: [
        .target(
            name: "AbloxCore",
            path: "AbloxStudio.swiftpm/Sources",
            // Everything that needs SwiftUI, RealityKit or Network is carved
            // out: what remains is portable Swift that builds anywhere.
            exclude: [
                "Net",
                "Engine",
                "Editor",
                "UI",
                "StudioApp.swift"
            ]
        ),
        .testTarget(
            name: "AbloxCoreTests",
            dependencies: ["AbloxCore"],
            path: "Tests/AbloxCoreTests"
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["AbloxCore"],
            path: "Tests/EditorCoreTests"
        )
    ]
)
