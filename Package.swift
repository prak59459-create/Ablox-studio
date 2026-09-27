// swift-tools-version: 5.9
import PackageDescription

// As in the Ablox client repository, this manifest exists so the portable
// layers can be built and unit-tested off-device, including on Linux CI.
// It points at the same sources the iPad app compiles.
//
// The shipping app is `AbloxStudio.swiftpm` — that is what you open in Swift
// Playgrounds. Its `AbloxCore` target is the same as the one below: the
// mirrored core and Studio's own `EditorCore`, compiled together as one
// module, which the app's other files import.
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
            // Only what builds anywhere: SwiftUI, RealityKit and Network stay
            // with the app.
            sources: ["AbloxCore", "EditorCore"]
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
