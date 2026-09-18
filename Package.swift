// swift-tools-version: 5.9
import PackageDescription

// As in the Ablox client repository, this manifest exists so the portable
// layers can be built and unit-tested off-device, including on Linux CI.
// It points at the same sources the iPad app compiles.
//
// The shipping app is `AbloxStudio.swiftpm` — that is what you open in Swift
// Playgrounds.
//
// `AbloxCore` here is a mirror of the canonical copy in the Ablox client
// repository; `scripts/sync-core.sh --check` fails the build if they drift.
// `EditorCore` is Studio's own: the undoable document model.
let package = Package(
    name: "AbloxStudioCore",
    products: [
        .library(name: "AbloxCore", targets: ["AbloxCore"]),
        .library(name: "EditorCore", targets: ["EditorCore"])
    ],
    targets: [
        .target(
            name: "AbloxCore",
            path: "AbloxStudio.swiftpm/Sources/AbloxCore"
        ),
        .target(
            name: "EditorCore",
            dependencies: ["AbloxCore"],
            path: "AbloxStudio.swiftpm/Sources/EditorCore"
        ),
        .testTarget(
            name: "AbloxCoreTests",
            dependencies: ["AbloxCore"],
            path: "Tests/AbloxCoreTests"
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore", "AbloxCore"],
            path: "Tests/EditorCoreTests"
        )
    ]
)
