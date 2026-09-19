import Foundation

// MARK: - Why a session ended

/// Why a client stopped being connected.
///
/// Structured rather than a string, because the app has to *decide* things
/// from it — whether to retry, what to tell the player, whether to go back to
/// the lobby. A human-readable sentence cannot be reasoned about, and
/// `reason.contains("timeout")` is how that decision goes wrong later.
public enum DisconnectReason: Hashable, Sendable {

    /// The player tapped Leave. Never retried.
    case userLeft

    /// The host shut the world down. Retrying would reconnect to nothing.
    case hostClosed

    /// The TLS handshake failed — in practice, the wrong room code. Retrying
    /// would fail identically, and hammering it five times with backoff just
    /// delays telling the player the thing they can actually fix.
    case authenticationFailed

    /// The peers are running incompatible builds.
    case protocolMismatch

    /// The session is at capacity.
    case sessionFull

    /// The connection dropped: Wi-Fi blip, the iPad slept, someone walked out
    /// of range. This is the case reconnection exists for.
    case networkLost

    /// The peer stopped answering.
    case timedOut

    /// Anything unrecognised. Retried, but cautiously — see `isRetryable`.
    case unknown(String)

    /// Whether reconnecting stands a chance of working.
    ///
    /// The distinction is the whole point: a transient network fault deserves
    /// a quiet retry, a wrong room code deserves a message.
    public var isRetryable: Bool {
        switch self {
        case .networkLost, .timedOut, .unknown:
            return true
        case .userLeft, .hostClosed, .authenticationFailed, .protocolMismatch, .sessionFull:
            return false
        }
    }

    /// What the player is told. Phrased as something they can act on where
    /// there is an action; plain where there is not.
    public var message: String {
        switch self {
        case .userLeft:
            return "You left the world."
        case .hostClosed:
            return "The host closed the world."
        case .authenticationFailed:
            return "Could not connect — check the room code is the same on both iPads."
        case .protocolMismatch:
            return "That iPad is running a different version of Ablox. Update both to play together."
        case .sessionFull:
            return "That world is full."
        case .networkLost:
            return "Lost connection to the host."
        case .timedOut:
            return "The host stopped responding."
        case let .unknown(detail):
            return detail.isEmpty ? "Disconnected." : detail
        }
    }
}

// MARK: - Reconnection policy

/// When, and how often, to try getting back into a session.
///
/// Pure arithmetic with the randomness injected, so the backoff curve and the
/// give-up condition are unit-testable rather than something you find out
/// about in a classroom.
public struct ReconnectPolicy: Hashable, Sendable {

    /// How many attempts before giving up and sending the player to the lobby.
    public var maximumAttempts: Int

    /// Delay before the first retry. Short, because the overwhelmingly common
    /// case — an iPad coming back from a few seconds in the background — is
    /// usually fixed on the first try.
    public var baseDelay: Double

    /// Ceiling on the backoff, so the last attempts are not minutes apart.
    public var maximumDelay: Double

    /// Fraction of the delay to randomise, in `0...1`.
    ///
    /// This matters more than it looks. When a host's Wi-Fi blips, *every*
    /// client drops at the same instant; without jitter they would all retry
    /// in lockstep and arrive as a thundering herd on a host that is itself
    /// still recovering.
    public var jitterFraction: Double

    /// Total seconds to keep trying, regardless of attempt count. A player
    /// staring at "Reconnecting…" for a minute would rather be told.
    public var giveUpAfter: Double

    public init(
        maximumAttempts: Int = 5,
        baseDelay: Double = 0.5,
        maximumDelay: Double = 8,
        jitterFraction: Double = 0.25,
        giveUpAfter: Double = 45
    ) {
        self.maximumAttempts = maximumAttempts
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
        self.giveUpAfter = giveUpAfter
    }

    public static let `default` = ReconnectPolicy()

    /// Never retries. For tests, and for a host, which has nothing to
    /// reconnect *to*.
    public static let none = ReconnectPolicy(maximumAttempts: 0, giveUpAfter: 0)

    /// Seconds to wait before attempt number `attempt` (1-based).
    ///
    /// Exponential, capped, then jittered downward only — a jitter that could
    /// *extend* past the cap would defeat the cap.
    ///
    /// - Parameter randomFraction: `0...1`, injected so tests are
    ///   deterministic. Production passes a real random value.
    public func delay(forAttempt attempt: Int, randomFraction: Double) -> Double {
        guard attempt >= 1 else { return 0 }

        let exponential = baseDelay * pow(2, Double(attempt - 1))
        let capped = Swift.min(exponential, maximumDelay)

        let clampedFraction = Swift.max(0, Swift.min(1, randomFraction))
        let jitterRange = capped * Swift.max(0, Swift.min(1, jitterFraction))
        // Subtracted, so the delay lands in [capped - jitter, capped].
        return Swift.max(0, capped - jitterRange * clampedFraction)
    }

    public func delay(forAttempt attempt: Int) -> Double {
        delay(forAttempt: attempt, randomFraction: Double.random(in: 0...1))
    }

    /// Whether to make attempt number `attempt`.
    ///
    /// - Parameters:
    ///   - reason: why the session ended.
    ///   - attempt: the attempt about to be made, 1-based.
    ///   - elapsed: seconds since the disconnect.
    public func shouldAttempt(after reason: DisconnectReason, attempt: Int, elapsed: Double) -> Bool {
        guard reason.isRetryable else { return false }
        guard attempt >= 1, attempt <= maximumAttempts else { return false }
        guard elapsed < giveUpAfter else { return false }
        return true
    }
}

// MARK: - Reconnection state machine

/// Tracks an in-progress reconnection.
///
/// Separated from the networking so the sequence — drop, wait, try, wait
/// longer, give up — can be stepped through in a test with a fake clock,
/// rather than by pulling a Wi-Fi cable and watching.
public struct ReconnectCoordinator: Sendable {

    public enum Status: Hashable, Sendable {
        /// Connected, or never connected.
        case idle
        /// Waiting out the backoff before the next attempt.
        case waiting(attempt: Int, until: Double)
        /// An attempt is in flight.
        case attempting(attempt: Int)
        /// Stopped trying. Carries why.
        case gaveUp(DisconnectReason)

        public var isReconnecting: Bool {
            switch self {
            case .waiting, .attempting: return true
            case .idle, .gaveUp: return false
            }
        }

        /// 1-based attempt number, for "Reconnecting… (2 of 5)".
        public var attemptNumber: Int? {
            switch self {
            case let .waiting(attempt, _), let .attempting(attempt): return attempt
            case .idle, .gaveUp: return nil
            }
        }
    }

    public private(set) var status: Status = .idle
    public var policy: ReconnectPolicy

    private var reason: DisconnectReason?
    private var disconnectedAt: Double = 0
    private var attempt: Int = 0

    public init(policy: ReconnectPolicy = .default) {
        self.policy = policy
    }

    public var isReconnecting: Bool { status.isReconnecting }

    /// Total attempts allowed, for display.
    public var maximumAttempts: Int { policy.maximumAttempts }

    /// Records a disconnect and schedules the first retry, if the reason
    /// warrants one.
    ///
    /// - Returns: the status, so the caller can render it without re-reading.
    @discardableResult
    public mutating func disconnected(
        reason: DisconnectReason,
        at time: Double,
        randomFraction: Double = Double.random(in: 0...1)
    ) -> Status {
        self.reason = reason
        disconnectedAt = time
        attempt = 0

        guard policy.shouldAttempt(after: reason, attempt: 1, elapsed: 0) else {
            status = .gaveUp(reason)
            return status
        }

        attempt = 1
        status = .waiting(
            attempt: 1,
            until: time + policy.delay(forAttempt: 1, randomFraction: randomFraction)
        )
        return status
    }

    /// Call on every tick. Returns true when it is time to make an attempt;
    /// the caller then actually reconnects and reports the outcome.
    public mutating func shouldAttemptNow(at time: Double) -> Bool {
        guard case let .waiting(attempt, until) = status, time >= until else { return false }

        // The overall deadline is re-checked here rather than only at
        // scheduling time: a long backoff can push an attempt past it.
        guard let reason, policy.shouldAttempt(after: reason, attempt: attempt, elapsed: time - disconnectedAt) else {
            status = .gaveUp(reason ?? .unknown(""))
            return false
        }

        status = .attempting(attempt: attempt)
        return true
    }

    /// The attempt failed; schedule the next one or give up.
    @discardableResult
    public mutating func attemptFailed(
        at time: Double,
        randomFraction: Double = Double.random(in: 0...1)
    ) -> Status {
        guard let reason else {
            status = .idle
            return status
        }

        let next = attempt + 1
        let delay = policy.delay(forAttempt: next, randomFraction: randomFraction)

        // Validated against when the attempt would actually *run*, not against
        // now. Scheduling an attempt that the deadline will reject on arrival
        // leaves the player watching "Reconnecting…" for the whole backoff
        // before being told something we already knew.
        let elapsedAtAttempt = (time - disconnectedAt) + delay
        guard policy.shouldAttempt(after: reason, attempt: next, elapsed: elapsedAtAttempt) else {
            status = .gaveUp(reason)
            return status
        }

        attempt = next
        status = .waiting(attempt: next, until: time + delay)
        return status
    }

    /// Reconnected. Clears everything, so a later drop starts from attempt one
    /// with a short delay rather than inheriting the previous backoff.
    public mutating func succeeded() {
        status = .idle
        reason = nil
        attempt = 0
        disconnectedAt = 0
    }

    /// Stops trying — the player asked to leave, or went back to the lobby.
    public mutating func cancel() {
        status = .idle
        reason = nil
        attempt = 0
    }

    /// Brings the next attempt forward to now.
    ///
    /// Called when the app returns to the foreground: the iPad has just
    /// regained its network, so waiting out a backoff that was scheduled while
    /// it was asleep only adds delay the player can see.
    public mutating func retryImmediately(at time: Double) {
        guard case let .waiting(attempt, _) = status else { return }
        status = .waiting(attempt: attempt, until: time)
    }

    /// What to show while reconnecting.
    public var progressDescription: String? {
        guard let number = status.attemptNumber else { return nil }
        return "Reconnecting… (\(number) of \(policy.maximumAttempts))"
    }

    /// Why it gave up, if it did.
    public var failureReason: DisconnectReason? {
        if case let .gaveUp(reason) = status { return reason }
        return nil
    }
}
