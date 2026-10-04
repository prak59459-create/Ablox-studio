import Foundation

/// A little movement each iPad gives a block by itself — spinning, swaying,
/// dancing — with nothing sent over the network, so a hundred pets on their
/// stands can all be alive at once.
///
/// It turns and stretches the block about its own middle (for a group, about
/// the block the others hang from), and never moves it: a block can sway and
/// be carried along by `move_to` at the same time. Optional on `BlockData`;
/// an iPad that has not updated shows the block still.
public struct BlockAnimation: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, CaseIterable, Sendable, ComparedByCase {
        /// Turning round and round.
        case spin
        /// Rocking from side to side.
        case sway
        /// Rocking, turning a little and bouncing: alive and happy.
        case dance
        /// Squashing and stretching, as if hopping on the spot.
        case bounce
        /// Growing and shrinking a little.
        case pulse
        /// Tipping forward and back.
        case wobble
    }

    public var kind: Kind
    /// Times the usual speed.
    public var speed: Float

    public static let speeds: ClosedRange<Float> = 0.1...5

    public init(kind: Kind, speed: Float = 1) {
        self.kind = kind
        self.speed = speed.isFinite ? Swift.min(Swift.max(speed, Self.speeds.lowerBound), Self.speeds.upperBound) : 1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try container.decode(Kind.self, forKey: .kind),
                  speed: try container.decodeIfPresent(Float.self, forKey: .speed) ?? 1)
    }

    /// The turn (degrees about x, y and z) and the stretch (times the size on
    /// each axis) at `time` seconds, started at `phase` (0…1) so blocks that
    /// share an animation do not move in step.
    public func pose(at time: Double, phase: Double) -> (degrees: Vec3, stretch: Vec3) {
        // Every step typed: Double and Float mixed in one expression is slow
        // for the compiler to work out.
        let t: Double = time * Double(speed) + phase * 10
        let still = Vec3(1, 1, 1)
        switch kind {
        case .spin:
            let turned: Double = (t * 90).truncatingRemainder(dividingBy: 360)
            return (Vec3(0, Float(turned), 0), still)
        case .sway:
            let lean: Double = sin(t * 2.4) * 10
            return (Vec3(0, 0, Float(lean)), still)
        case .dance:
            let beat: Double = sin(t * 5)
            let squash = Float(1 + abs(beat) * 0.08)
            let thin: Float = 1 / squash.squareRoot()
            let twist: Double = sin(t * 2.5) * 18
            let tilt: Double = beat * 9
            return (Vec3(0, Float(twist), Float(tilt)), Vec3(thin, squash, thin))
        case .bounce:
            let hop: Double = sin(t * 6)
            let y = Float(1 + hop * 0.1)
            let side = Float(1 - hop * 0.05)
            return (Vec3(0, 0, 0), Vec3(side, y, side))
        case .pulse:
            let swell: Double = sin(t * 3) * 0.06
            let s = Float(1 + swell)
            return (Vec3(0, 0, 0), Vec3(s, s, s))
        case .wobble:
            let rock: Double = sin(t * 2.8) * 8
            return (Vec3(Float(rock), 0, 0), still)
        }
    }
}
