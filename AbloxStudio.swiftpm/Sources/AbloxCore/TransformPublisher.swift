import Foundation

/// Decides when an avatar's transform is worth sending.
///
/// ## Why this exists
///
/// Publishing every tick costs `players × rate` packets a second whether or
/// not anything moved. In a world where four people are standing around
/// deciding what to build — which is most of the time — that is entirely
/// wasted bandwidth on a Wi-Fi network shared with everything else in the
/// room.
///
/// This is the send half of **dead reckoning**: a peer that hears nothing new
/// assumes the avatar continued as it was, so a packet is only needed when
/// reality has diverged from that assumption by more than a threshold. The
/// receive half is `PlayerSnapshot.interpolated(toward:t:)`, which is what
/// makes the gaps invisible.
///
/// Deliberately a value type with an injected clock, so every branch below is
/// testable without a network or a device.
public struct TransformPublisher: Sendable {

    public struct Thresholds: Hashable, Sendable {
        /// Metres of divergence from the predicted position before a packet
        /// is worth sending.
        public var position: Float
        /// Degrees of facing change before a packet is worth sending.
        public var yawDegrees: Float
        /// Metres per second of velocity change — this is what makes a jump
        /// or a sudden stop send immediately rather than waiting out the
        /// position threshold.
        public var velocity: Float
        /// Seconds after which a packet is sent regardless. A keepalive: it
        /// bounds how stale a resting avatar can look to a peer that missed
        /// the last update, and stops a peer being marked gone.
        public var maximumSilence: Double
        /// Ceiling on send rate. Even a sprinting player never exceeds this.
        public var maximumRate: Double

        public init(
            position: Float = 0.05,
            yawDegrees: Float = 2.0,
            velocity: Float = 0.5,
            maximumSilence: Double = 1.0,
            maximumRate: Double = AbloxProtocol.transformHz
        ) {
            self.position = position
            self.yawDegrees = yawDegrees
            self.velocity = velocity
            self.maximumSilence = maximumSilence
            self.maximumRate = maximumRate
        }

        public static let `default` = Thresholds()

        /// Looser thresholds for a crowded session, traded against precision.
        public static let conservative = Thresholds(
            position: 0.15,
            yawDegrees: 5,
            velocity: 1.0,
            maximumSilence: 1.5,
            maximumRate: 10
        )
    }

    public var thresholds: Thresholds

    /// What peers currently believe, i.e. the last snapshot actually sent.
    private var lastSent: PlayerSnapshot?
    private var lastSentAt: Double = -.greatestFiniteMagnitude

    // Counters, so the effect of the whole scheme is measurable rather than
    // assumed. Surfaced in Settings as a diagnostics line.
    public private(set) var consideredCount: Int = 0
    public private(set) var sentCount: Int = 0

    public init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Proportion of ticks that produced no packet. 0 before anything is
    /// considered.
    public var suppressionRate: Double {
        guard consideredCount > 0 else { return 0 }
        return Double(consideredCount - sentCount) / Double(consideredCount)
    }

    /// Where a peer would believe this avatar is, `elapsed` seconds after the
    /// last packet, by continuing its last known velocity.
    ///
    /// This is the prediction peers make, so it is the thing the local
    /// simulation has to be compared against — comparing against the raw last
    /// *sent* position instead would send constantly during steady running,
    /// which is exactly the case dead reckoning is meant to cover.
    public func predictedPosition(after elapsed: Double) -> Vec3? {
        guard let lastSent else { return nil }
        return lastSent.position + lastSent.velocity * Float(Swift.max(0, elapsed))
    }

    /// Whether `snapshot` should go out now.
    ///
    /// Mutating because a `true` answer records what peers will then believe.
    /// Callers must send exactly when this returns true, or the model of the
    /// remote view drifts out of step with reality.
    public mutating func shouldPublish(_ snapshot: PlayerSnapshot, at time: Double) -> Bool {
        consideredCount += 1

        // Nothing sent yet: peers know nothing, so send.
        guard let previous = lastSent else {
            record(snapshot, at: time)
            return true
        }

        let elapsed = time - lastSentAt

        // Rate ceiling comes first: it caps everything below it.
        if elapsed < 1.0 / Swift.max(1, thresholds.maximumRate) {
            return false
        }

        // Keepalive.
        if elapsed >= thresholds.maximumSilence {
            record(snapshot, at: time)
            return true
        }

        // Compare against what peers are *predicting*, not against the last
        // sent position.
        let predicted = previous.position + previous.velocity * Float(elapsed)
        if predicted.distance(to: snapshot.position) >= thresholds.position {
            record(snapshot, at: time)
            return true
        }

        if abs(angularDelta(from: previous.yawDegrees, to: snapshot.yawDegrees)) >= thresholds.yawDegrees {
            record(snapshot, at: time)
            return true
        }

        // A velocity change means the prediction is about to go wrong even if
        // the position still matches — the moment a jump starts, or a runner
        // stops dead.
        if (snapshot.velocity - previous.velocity).length >= thresholds.velocity {
            record(snapshot, at: time)
            return true
        }

        // Leaving or touching the ground changes how the avatar is drawn, and
        // is cheap to send.
        if snapshot.isGrounded != previous.isGrounded {
            record(snapshot, at: time)
            return true
        }

        return false
    }

    private mutating func record(_ snapshot: PlayerSnapshot, at time: Double) {
        lastSent = snapshot
        lastSentAt = time
        sentCount += 1
    }

    /// Forgets the remote view. Called on (re)connect, where peers genuinely
    /// know nothing and the next tick must send.
    public mutating func reset() {
        lastSent = nil
        lastSentAt = -.greatestFiniteMagnitude
    }

    public mutating func resetStatistics() {
        consideredCount = 0
        sentCount = 0
    }
}
