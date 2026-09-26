import Foundation

// What the host checks about a guest before believing or relaying anything.
//
// A joined iPad is a friend's, but its app may not be ours: anything that
// arrives over the network is a claim. These are the checks that need no
// networking to test, so they live here; `AbloxHost` applies them.

// MARK: - Packet budget

/// How much of each kind of packet one connection may send.
///
/// A token bucket per kind: steady play never comes near the rate, a burst
/// (a flurry of button presses) is absorbed, and a flood is dropped before
/// it reaches the game or is relayed to everyone else. A connection that
/// keeps flooding is cut off — it is either broken or trying to be.
public struct PacketBudget: Sendable {

    public enum Verdict: Equatable, Sendable {
        case allow
        case drop
        case disconnect
    }

    /// Per second, and how many can come at once.
    public static let limits: [PacketKind: (rate: Double, burst: Double)] = [
        // Clients send at most `AbloxProtocol.transformHz`; twice that leaves
        // room for jitter.
        .playerTransform: (40, 60),
        .playerInput: (25, 40),
        .eventTrigger: (40, 80),
        .chat: (1.5, 6),
        // Studio co-editing: a drag sends one edit a frame.
        .worldDelta: (400, 800),
        .handshake: (1, 3),
        .ping: (5, 10),
        .pong: (5, 10),
        .leave: (2, 4)
    ]

    /// Dropped packets in `window` seconds that end the connection.
    public static let floodLimit = 300
    public static let window: Double = 10

    private struct Bucket: Sendable {
        var tokens: Double
        var last: Double
    }

    private var buckets: [PacketKind: Bucket] = [:]
    private var drops: [Double] = []

    public init() {}

    public mutating func admit(_ kind: PacketKind, at time: Double) -> Verdict {
        // Kinds a guest never sends (world snapshots, rosters, effects) have
        // no budget; the host ignores them anyway.
        guard let limit = Self.limits[kind] else { return .allow }
        var bucket = buckets[kind] ?? Bucket(tokens: limit.burst, last: time)
        bucket.tokens = Swift.min(limit.burst, bucket.tokens + Swift.max(0, time - bucket.last) * limit.rate)
        bucket.last = time
        if bucket.tokens >= 1 {
            bucket.tokens -= 1
            buckets[kind] = bucket
            return .allow
        }
        buckets[kind] = bucket
        drops.append(time)
        drops.removeAll { time - $0 > Self.window }
        return drops.count > Self.floodLimit ? .disconnect : .drop
    }
}

// MARK: - Failed attempts

/// Remembers addresses that keep failing to get in — wrong room codes,
/// half-open connections — and turns them away for a while.
///
/// Guessing a six-character code online is already hopeless at the rate a
/// TLS handshake allows; this keeps it that way and stops one device from
/// tying up the host with connections that never finish.
public struct AttemptLimiter: Sendable {
    public static let maximumFailures = 15
    public static let window: Double = 60
    public static let banDuration: Double = 120

    private var failures: [String: [Double]] = [:]
    private var bannedUntil: [String: Double] = [:]

    public init() {}

    public func isBanned(_ address: String, at time: Double) -> Bool {
        (bannedUntil[address] ?? -.infinity) > time
    }

    public mutating func recordFailure(_ address: String, at time: Double) {
        var list = (failures[address] ?? []).filter { time - $0 <= Self.window }
        list.append(time)
        failures[address] = list
        if list.count >= Self.maximumFailures {
            bannedUntil[address] = time + Self.banDuration
            failures[address] = []
        }
    }

    public mutating func recordSuccess(_ address: String) {
        failures[address] = nil
    }
}

// MARK: - Transforms

public extension PlayerTransformPayload {
    /// No world is bigger than this; a position outside it is garbage or a
    /// trick, and NaN would poison every distance check it touched.
    static let maximumCoordinate: Float = 100_000
    static let maximumSpeed: Float = 2_000

    var isPlausible: Bool {
        let values = [position.x, position.y, position.z, velocity.x, velocity.y, velocity.z, yawDegrees]
        guard values.allSatisfy(\.isFinite) else { return false }
        guard abs(position.x) < Self.maximumCoordinate, abs(position.y) < Self.maximumCoordinate,
              abs(position.z) < Self.maximumCoordinate else { return false }
        return velocity.length < Self.maximumSpeed
    }
}

// MARK: - Profiles

public extension AvatarProfile {
    static let maximumNameLength = 24
    /// What a player may choose for themselves. A script can still make
    /// someone a giant with `p.size`; the host decides that, not the guest.
    static let chosenHeightRange: ClosedRange<Float> = 0.5...1.6

    /// The profile as a guest sent it, made safe to show everyone: a short
    /// single-line name, a sensible size, real colours.
    func sanitizedForNetwork() -> AvatarProfile {
        var copy = self
        let cleaned = displayName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayName = String(name.prefix(Self.maximumNameLength))
        if copy.displayName.isEmpty { copy.displayName = "Player" }
        copy.height = height.isFinite ? Swift.min(Swift.max(height, Self.chosenHeightRange.lowerBound), Self.chosenHeightRange.upperBound) : 1
        copy.bodyColor = bodyColor.clamped
        copy.headColor = headColor.clamped
        copy.accentColor = accentColor.clamped
        copy.rideColor = rideColor.clamped
        return copy
    }
}

extension ColorRGBA {
    /// Every channel a real number from 0 to 1.
    var clamped: ColorRGBA {
        func unit(_ v: Float) -> Float { v.isFinite ? Swift.min(1, Swift.max(0, v)) : 0 }
        return ColorRGBA(r: unit(r), g: unit(g), b: unit(b), a: unit(a))
    }
}
