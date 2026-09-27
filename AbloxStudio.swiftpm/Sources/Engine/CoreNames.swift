import AbloxCore

// Names the core shares with Apple's frameworks: SwiftUI has a `Gesture`,
// RealityKit a `BoundingBox`, AudioToolbox a `MusicTrack`. Declared here, in the app's own module, these
// win over both imports, so every file means the core's — as it did when the
// core was compiled into the app — and SwiftUI's is written
// `SwiftUI.Gesture` where it is wanted.
public typealias Gesture = AbloxCore.Gesture
public typealias BoundingBox = AbloxCore.BoundingBox
public typealias MusicTrack = AbloxCore.MusicTrack
