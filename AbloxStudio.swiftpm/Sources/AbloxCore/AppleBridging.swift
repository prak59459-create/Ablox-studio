import Foundation

// Everything in this file is Apple-only. `AbloxCore` itself is deliberately
// portable — it builds and unit-tests on Linux — so the bridges to `simd`,
// SwiftUI and RealityKit live behind `canImport` guards rather than forcing
// the whole module to depend on them.

#if canImport(simd)
import simd

public extension Vec3 {
    init(_ v: SIMD3<Float>) {
        self.init(v.x, v.y, v.z)
    }

    var simd: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

public extension SIMD3 where Scalar == Float {
    init(_ v: Vec3) {
        self.init(v.x, v.y, v.z)
    }
}

public extension Quat {
    init(_ q: simd_quatf) {
        self.init(x: q.vector.x, y: q.vector.y, z: q.vector.z, w: q.vector.w)
    }

    var simd: simd_quatf {
        simd_quatf(ix: x, iy: y, iz: z, r: w)
    }
}
#endif

#if canImport(RealityKit) && !os(watchOS)
import RealityKit

public extension Transform3D {
    init(_ t: RealityKit.Transform) {
        self.init(
            position: Vec3(t.translation),
            rotation: Quat(t.rotation),
            scale: Vec3(t.scale)
        )
    }

    /// The RealityKit transform this describes.
    var realityKit: RealityKit.Transform {
        RealityKit.Transform(
            scale: scale.simd,
            rotation: rotation.simd,
            translation: position.simd
        )
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

public extension Color {
    init(_ rgba: ColorRGBA) {
        self.init(
            .sRGB,
            red: Double(rgba.r),
            green: Double(rgba.g),
            blue: Double(rgba.b),
            opacity: Double(rgba.a)
        )
    }
}

public extension ColorRGBA {
    /// Best-effort conversion back from SwiftUI. Only used by the Studio's
    /// colour picker, which hands back sRGB components.
    #if canImport(UIKit)
    init(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Float(r), g: Float(g), b: Float(b), a: Float(a))
    }

    init(_ color: Color) {
        self.init(uiColor: UIColor(color))
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
    #endif

    var swiftUIColor: Color { Color(self) }
}
#endif

#if canImport(UIKit)
import UIKit
#endif
