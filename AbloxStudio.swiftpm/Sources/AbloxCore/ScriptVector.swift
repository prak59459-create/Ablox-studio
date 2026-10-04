import Foundation

// A script's vector and its arithmetic, and the scripts' one addition to
// `Double`, in a file of their own: `+`, `-` and `*` written for a type make
// every file that adds or multiplies anything depend on the file that type
// is in, and an extension of `Double` every file that uses a number
// (AbloxCore/Comparisons.swift says why). So they live where nothing else
// changes.

/// A position or direction, as scripts see one: a map with numbers at `x`,
/// `y` and `z`.
///
/// Not a separate value type. `{x: 1, y: 2, z: 3}` is already how a script
/// writes a position and how `p.position` reads back, so arithmetic on maps of
/// that shape is all a vector needs to be.
public struct ScriptVector: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ v: Vec3) {
        self.init(Double(v.x), Double(v.y), Double(v.z))
    }

    /// Nil unless the value is a map with numeric `x`, `y` and `z`.
    public init?(_ value: ScriptValue) {
        guard case let .map(map) = value,
              case let .number(x) = map["x"] ?? .null,
              case let .number(y) = map["y"] ?? .null,
              case let .number(z) = map["z"] ?? .null else { return nil }
        self.init(x, y, z)
    }

    public var value: ScriptValue {
        let map = ScriptMap()
        map["x"] = .number(x)
        map["y"] = .number(y)
        map["z"] = .number(z)
        return .map(map)
    }

    public var vec3: Vec3 { Vec3(Float(x), Float(y), Float(z)) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public static func + (a: ScriptVector, b: ScriptVector) -> ScriptVector { ScriptVector(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: ScriptVector, b: ScriptVector) -> ScriptVector { ScriptVector(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: ScriptVector, n: Double) -> ScriptVector { ScriptVector(a.x * n, a.y * n, a.z * n) }
}

extension Double {
    /// This number as a whole number for a position, a count or a number of
    /// digits: nan is 0 and anything past ±10¹⁵ stops there. A script can
    /// make both (`sqrt(-1)`, `exp(700) * exp(700)`), and `Int(_:)` of either
    /// would stop the whole app rather than the script.
    var scriptInt: Int {
        guard !isNaN else { return 0 }
        return Int(Swift.min(Swift.max(self, -1e15), 1e15))
    }
}
