import Foundation

// MARK: - Vec3

/// A portable three-component vector.
///
/// `AbloxCore` deliberately avoids Apple's `simd` module so that the entire
/// data model and wire format can be compiled and unit-tested on any Swift
/// platform, including Linux CI. On Apple platforms `Vec3` bridges to
/// `SIMD3<Float>` for free — see `AppleBridging.swift`.
///
/// Coordinate system matches RealityKit: right-handed, +Y up, -Z forward.
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(x: Float, y: Float, z: Float) {
        self.init(x, y, z)
    }

    public init(repeating value: Float) {
        self.init(value, value, value)
    }

    public static let zero = Vec3(0, 0, 0)
    public static let one = Vec3(1, 1, 1)

    /// +Y. RealityKit's up axis.
    public static let up = Vec3(0, 1, 0)
    /// -Z. RealityKit cameras look down their local -Z axis.
    public static let forward = Vec3(0, 0, -1)
    /// +X.
    public static let right = Vec3(1, 0, 0)
}

public extension Vec3 {
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x * b.x, a.y * b.y, a.z * b.z) }
    static func / (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x / b.x, a.y / b.y, a.z / b.z) }
    static func * (v: Vec3, s: Float) -> Vec3 { Vec3(v.x * s, v.y * s, v.z * s) }
    static func * (s: Float, v: Vec3) -> Vec3 { v * s }
    static func / (v: Vec3, s: Float) -> Vec3 { Vec3(v.x / s, v.y / s, v.z / s) }
    static prefix func - (v: Vec3) -> Vec3 { Vec3(-v.x, -v.y, -v.z) }

    static func += (a: inout Vec3, b: Vec3) { a = a + b }
    static func -= (a: inout Vec3, b: Vec3) { a = a - b }
    static func *= (a: inout Vec3, s: Float) { a = a * s }

    func dot(_ other: Vec3) -> Float { x * other.x + y * other.y + z * other.z }

    func cross(_ other: Vec3) -> Vec3 {
        Vec3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    var lengthSquared: Float { dot(self) }
    var length: Float { lengthSquared.squareRoot() }

    /// Unit-length copy. Returns `.zero` for a degenerate vector rather than NaN.
    var normalized: Vec3 {
        let len = length
        guard len > 1e-6 else { return .zero }
        return self / len
    }

    func distance(to other: Vec3) -> Float { (self - other).length }

    /// Horizontal (XZ-plane) distance, ignoring height. Used by proximity
    /// triggers so a player standing on a tall block still counts as "near".
    func horizontalDistance(to other: Vec3) -> Float {
        let dx = x - other.x
        let dz = z - other.z
        return (dx * dx + dz * dz).squareRoot()
    }

    static func lerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 {
        a + (b - a) * t
    }

    func componentMin(_ other: Vec3) -> Vec3 {
        Vec3(Swift.min(x, other.x), Swift.min(y, other.y), Swift.min(z, other.z))
    }

    func componentMax(_ other: Vec3) -> Vec3 {
        Vec3(Swift.max(x, other.x), Swift.max(y, other.y), Swift.max(z, other.z))
    }

    func clamped(min lo: Vec3, max hi: Vec3) -> Vec3 {
        componentMax(lo).componentMin(hi)
    }

    /// Snaps each component to the nearest multiple of `step`.
    /// `step <= 0` returns the vector unchanged, which lets the Studio's
    /// grid-snap toggle be a single value rather than a value plus a flag.
    func snapped(toGridOf step: Float) -> Vec3 {
        guard step > 0 else { return self }
        return Vec3(
            (x / step).rounded() * step,
            (y / step).rounded() * step,
            (z / step).rounded() * step
        )
    }

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

extension Vec3: CustomStringConvertible {
    public var description: String {
        String(format: "(%.3f, %.3f, %.3f)", x, y, z)
    }
}

// MARK: - Quat

/// A unit quaternion, stored xyzw to match `simd_quatf`'s vector layout.
///
/// Euler conversions use intrinsic **Y-X-Z** order (yaw, then pitch, then
/// roll), which is the convention the Studio inspector exposes: yaw is the
/// control you reach for most when placing blocks, so it is applied first and
/// stays gimbal-stable for the common case of pitch near zero.
public struct Quat: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    public init(axis: Vec3, angle: Float) {
        let n = axis.normalized
        let half = angle * 0.5
        let s = sin(half)
        self.init(x: n.x * s, y: n.y * s, z: n.z * s, w: cos(half))
    }
}

public extension Quat {
    /// Builds a rotation from Euler angles in **degrees** (pitch=x, yaw=y, roll=z).
    static func euler(degrees e: Vec3) -> Quat {
        euler(radians: Vec3(e.x * .pi / 180, e.y * .pi / 180, e.z * .pi / 180))
    }

    /// Builds a rotation from Euler angles in radians, intrinsic Y-X-Z order.
    static func euler(radians e: Vec3) -> Quat {
        let yaw = Quat(axis: .up, angle: e.y)
        let pitch = Quat(axis: .right, angle: e.x)
        let roll = Quat(axis: Vec3(0, 0, 1), angle: e.z)
        return (yaw * pitch * roll).normalized
    }

    /// Decomposes back to degrees. Round-trips `euler(degrees:)` for angles
    /// away from the pitch = ±90° singularity, where yaw and roll fold
    /// together and roll is pinned to zero.
    var eulerDegrees: Vec3 {
        let r = eulerRadians
        return Vec3(r.x * 180 / .pi, r.y * 180 / .pi, r.z * 180 / .pi)
    }

    var eulerRadians: Vec3 {
        let q = normalized
        // Y-X-Z intrinsic decomposition.
        let sinPitch = 2 * (q.w * q.x - q.y * q.z)
        if abs(sinPitch) >= 0.99999 {
            // Gimbal lock: fold roll into yaw.
            let pitch = Float(sinPitch > 0 ? Float.pi / 2 : -Float.pi / 2)
            let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
            return Vec3(pitch, yaw, 0)
        }
        let pitch = asin(sinPitch)
        let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
        let roll = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.x * q.x + q.z * q.z))
        return Vec3(pitch, yaw, roll)
    }

    /// Hamilton product. `a * b` applies `b` first, then `a`.
    static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    var lengthSquared: Float { x * x + y * y + z * z + w * w }

    var normalized: Quat {
        let len = lengthSquared.squareRoot()
        guard len > 1e-6 else { return .identity }
        return Quat(x: x / len, y: y / len, z: z / len, w: w / len)
    }

    var inverse: Quat {
        let q = normalized
        return Quat(x: -q.x, y: -q.y, z: -q.z, w: q.w)
    }

    /// Rotates `v` by this quaternion.
    func act(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let s = w
        return u * (2 * u.dot(v)) + v * (s * s - u.dot(u)) + u.cross(v) * (2 * s)
    }

    /// Shortest-arc spherical interpolation.
    static func slerp(_ a: Quat, _ b: Quat, _ t: Float) -> Quat {
        var qa = a.normalized
        let qb = b.normalized
        var cosTheta = qa.x * qb.x + qa.y * qb.y + qa.z * qb.z + qa.w * qb.w

        // Take the short way around.
        if cosTheta < 0 {
            qa = Quat(x: -qa.x, y: -qa.y, z: -qa.z, w: -qa.w)
            cosTheta = -cosTheta
        }

        // Nearly parallel: lerp and renormalize, which avoids dividing by ~0.
        if cosTheta > 0.9995 {
            return Quat(
                x: qa.x + (qb.x - qa.x) * t,
                y: qa.y + (qb.y - qa.y) * t,
                z: qa.z + (qb.z - qa.z) * t,
                w: qa.w + (qb.w - qa.w) * t
            ).normalized
        }

        let theta = acos(cosTheta)
        let sinTheta = sin(theta)
        let wa = sin((1 - t) * theta) / sinTheta
        let wb = sin(t * theta) / sinTheta
        return Quat(
            x: qa.x * wa + qb.x * wb,
            y: qa.y * wa + qb.y * wb,
            z: qa.z * wa + qb.z * wb,
            w: qa.w * wa + qb.w * wb
        ).normalized
    }

    /// Yaw-only rotation, in degrees. Avatars only ever yaw, so this is the
    /// cheap path used by the movement controller and the transform packets.
    static func yaw(degrees: Float) -> Quat {
        Quat(axis: .up, angle: degrees * .pi / 180)
    }
}

// MARK: - Transform3D

/// Position / rotation / scale, the only transform representation Ablox stores.
///
/// Composition below is the usual game-engine TRS concatenation. It is exact
/// for uniform scale and for parent rotations that are axis-aligned with the
/// child's scale axes. Non-uniform scale combined with an off-axis parent
/// rotation would mathematically produce shear, which TRS cannot represent —
/// the result is the closest TRS approximation. RealityKit has the same
/// limitation on `Entity.transform`, so the rendered scene and this headless
/// math agree.
public struct Transform3D: Codable, Hashable, Sendable {
    public var position: Vec3
    public var rotation: Quat
    public var scale: Vec3

    public init(position: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = .one) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = Transform3D()

    /// Interprets `self` as a local transform inside `parent` and returns the
    /// equivalent transform in `parent`'s space.
    public func concatenating(parent: Transform3D) -> Transform3D {
        Transform3D(
            position: parent.position + parent.rotation.act(position * parent.scale),
            rotation: (parent.rotation * rotation).normalized,
            scale: parent.scale * scale
        )
    }

    /// Transforms a point expressed in this transform's local space into the
    /// space the transform itself lives in.
    public func transform(point: Vec3) -> Vec3 {
        position + rotation.act(point * scale)
    }

    /// Inverse of `transform(point:)`.
    public func inverseTransform(point: Vec3) -> Vec3 {
        let translated = point - position
        let unrotated = rotation.inverse.act(translated)
        return Vec3(
            scale.x == 0 ? 0 : unrotated.x / scale.x,
            scale.y == 0 ? 0 : unrotated.y / scale.y,
            scale.z == 0 ? 0 : unrotated.z / scale.z
        )
    }
}

// MARK: - BoundingBox

/// An axis-aligned bounding box.
public struct BoundingBox: Codable, Hashable, Sendable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    public init(center: Vec3, size: Vec3) {
        let half = size * 0.5
        self.init(min: center - half, max: center + half)
    }

    public var center: Vec3 { (min + max) * 0.5 }
    public var size: Vec3 { max - min }

    public func contains(_ point: Vec3) -> Bool {
        point.x >= min.x && point.x <= max.x &&
        point.y >= min.y && point.y <= max.y &&
        point.z >= min.z && point.z <= max.z
    }

    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(min: min.componentMin(other.min), max: max.componentMax(other.max))
    }

    public func expanded(by amount: Float) -> BoundingBox {
        BoundingBox(min: min - Vec3(repeating: amount), max: max + Vec3(repeating: amount))
    }

    /// Inclusive overlap: boxes that merely touch count as intersecting.
    /// Right for "does this trigger fire", wrong for collision — see
    /// `penetrates(_:epsilon:)`.
    public func intersects(_ other: BoundingBox) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
        min.y <= other.max.y && max.y >= other.min.y &&
        min.z <= other.max.z && max.z >= other.min.z
    }

    /// Strict overlap: the boxes must interpenetrate by more than `epsilon`
    /// on **every** axis.
    ///
    /// Collision resolution needs this rather than `intersects`. A player
    /// standing on a floor has their feet exactly at the floor's top surface,
    /// which `intersects` reports as a hit — and the horizontal pass would
    /// then treat the floor as a wall and push them backwards off it.
    public func penetrates(_ other: BoundingBox, epsilon: Float = 1e-3) -> Bool {
        overlapDepth(with: other, on: .x) > epsilon &&
        overlapDepth(with: other, on: .y) > epsilon &&
        overlapDepth(with: other, on: .z) > epsilon
    }

    public enum Axis: Sendable { case x, y, z }

    /// How deeply two boxes overlap on one axis. Negative when they are apart.
    public func overlapDepth(with other: BoundingBox, on axis: Axis) -> Float {
        switch axis {
        case .x: return Swift.min(max.x, other.max.x) - Swift.max(min.x, other.min.x)
        case .y: return Swift.min(max.y, other.max.y) - Swift.max(min.y, other.min.y)
        case .z: return Swift.min(max.z, other.max.z) - Swift.max(min.z, other.min.z)
        }
    }

    /// Union of a sequence of boxes, or `nil` when empty. Used for
    /// "frame selection" in the Studio viewport.
    public static func containing<S: Sequence>(_ boxes: S) -> BoundingBox? where S.Element == BoundingBox {
        var result: BoundingBox?
        for box in boxes {
            result = result.map { $0.union(box) } ?? box
        }
        return result
    }
}

// MARK: - Ray

/// A ray in world space, used for tap-to-select picking.
public struct Ray: Sendable {
    public var origin: Vec3
    public var direction: Vec3

    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction.normalized
    }

    public func point(at distance: Float) -> Vec3 {
        origin + direction * distance
    }

    /// Slab-method ray/AABB intersection. Returns the nearest non-negative hit
    /// distance, or `nil` when the ray misses. A ray starting inside the box
    /// reports distance 0.
    public func intersects(_ box: BoundingBox) -> Float? {
        var tMin: Float = 0
        var tMax: Float = .greatestFiniteMagnitude

        let origins = [origin.x, origin.y, origin.z]
        let directions = [direction.x, direction.y, direction.z]
        let mins = [box.min.x, box.min.y, box.min.z]
        let maxs = [box.max.x, box.max.y, box.max.z]

        for axis in 0..<3 {
            let d = directions[axis]
            let o = origins[axis]
            if abs(d) < 1e-6 {
                // Parallel to this slab: miss unless the origin is within it.
                if o < mins[axis] || o > maxs[axis] { return nil }
                continue
            }
            let inv = 1 / d
            var t1 = (mins[axis] - o) * inv
            var t2 = (maxs[axis] - o) * inv
            if t1 > t2 { swap(&t1, &t2) }
            tMin = Swift.max(tMin, t1)
            tMax = Swift.min(tMax, t2)
            if tMin > tMax { return nil }
        }
        return tMin
    }

    /// Distance at which the ray crosses the horizontal plane at `height`,
    /// or `nil` if it never does. Backs "drop a new block where you tapped".
    public func intersectionWithHorizontalPlane(atHeight height: Float) -> Float? {
        guard abs(direction.y) > 1e-6 else { return nil }
        let t = (height - origin.y) / direction.y
        return t >= 0 ? t : nil
    }
}

// MARK: - Scalar helpers

@inlinable
public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

/// Wraps an angle in degrees into (-180, 180].
@inlinable
public func normalizeDegrees(_ degrees: Float) -> Float {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d <= -180 { d += 360 }
    return d
}

/// Shortest signed angular delta from `a` to `b`, in degrees.
@inlinable
public func angularDelta(from a: Float, to b: Float) -> Float {
    normalizeDegrees(b - a)
}
