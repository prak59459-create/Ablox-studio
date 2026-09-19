import XCTest
@testable import AbloxCore

/// Session resilience: getting back in after the iPad slept or Wi-Fi blipped.
final class ReconnectionTests: XCTestCase {

    // MARK: Which disconnects deserve a retry

    func testTransientFaultsAreRetryable() {
        XCTAssertTrue(DisconnectReason.networkLost.isRetryable)
        XCTAssertTrue(DisconnectReason.timedOut.isRetryable)
        XCTAssertTrue(DisconnectReason.unknown("something odd").isRetryable)
    }

    func testDeliberateAndUnfixableEndingsAreNotRetried() {
        // Retrying any of these either cannot work or is user-hostile.
        XCTAssertFalse(DisconnectReason.userLeft.isRetryable)
        XCTAssertFalse(DisconnectReason.hostClosed.isRetryable)
        XCTAssertFalse(DisconnectReason.authenticationFailed.isRetryable,
                       "hammering a wrong room code just delays telling the player")
        XCTAssertFalse(DisconnectReason.protocolMismatch.isRetryable)
        XCTAssertFalse(DisconnectReason.sessionFull.isRetryable)
    }

    func testEveryReasonHasSomethingToShowThePlayer() {
        let reasons: [DisconnectReason] = [
            .userLeft, .hostClosed, .authenticationFailed, .protocolMismatch,
            .sessionFull, .networkLost, .timedOut, .unknown("detail"), .unknown("")
        ]
        for reason in reasons {
            XCTAssertFalse(reason.message.isEmpty, "\(reason) has no message")
        }
    }

    func testTheRoomCodeMessageNamesTheFix() {
        // The one disconnect the player can actually do something about.
        XCTAssertTrue(DisconnectReason.authenticationFailed.message.lowercased().contains("room code"))
    }

    // MARK: Backoff

    func testBackoffGrowsExponentially() {
        let policy = ReconnectPolicy(baseDelay: 0.5, maximumDelay: 100, jitterFraction: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1, randomFraction: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 2, randomFraction: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 3, randomFraction: 0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 4, randomFraction: 0), 4.0, accuracy: 1e-9)
    }

    func testBackoffIsCapped() {
        let policy = ReconnectPolicy(baseDelay: 0.5, maximumDelay: 3, jitterFraction: 0)
        XCTAssertEqual(policy.delay(forAttempt: 10, randomFraction: 0), 3, accuracy: 1e-9)
    }

    func testJitterOnlyShortensNeverExceedsTheCap() {
        // A jitter that could extend past the ceiling would defeat the ceiling.
        let policy = ReconnectPolicy(baseDelay: 1, maximumDelay: 4, jitterFraction: 0.25)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let delay = policy.delay(forAttempt: 10, randomFraction: fraction)
            XCTAssertLessThanOrEqual(delay, 4.0 + 1e-9)
            XCTAssertGreaterThanOrEqual(delay, 3.0 - 1e-9, "jitter should not shorten below 75%")
        }
    }

    func testJitterSpreadsSimultaneousRetries() {
        // When a host's Wi-Fi blips every client drops at the same instant.
        // Without jitter they all come back in lockstep.
        let policy = ReconnectPolicy(baseDelay: 2, maximumDelay: 8, jitterFraction: 0.5)
        let delays = stride(from: 0.0, through: 1.0, by: 0.25).map {
            policy.delay(forAttempt: 2, randomFraction: $0)
        }
        XCTAssertGreaterThan(Set(delays).count, 1, "identical delays would be a thundering herd")
    }

    func testDelayIsNeverNegative() {
        let policy = ReconnectPolicy(baseDelay: 1, maximumDelay: 4, jitterFraction: 1.0)
        XCTAssertGreaterThanOrEqual(policy.delay(forAttempt: 3, randomFraction: 1.0), 0)
        XCTAssertEqual(policy.delay(forAttempt: 0, randomFraction: 0), 0)
    }

    // MARK: shouldAttempt

    func testAttemptsAreBounded() {
        let policy = ReconnectPolicy(maximumAttempts: 3, giveUpAfter: 1000)
        XCTAssertTrue(policy.shouldAttempt(after: .networkLost, attempt: 3, elapsed: 0))
        XCTAssertFalse(policy.shouldAttempt(after: .networkLost, attempt: 4, elapsed: 0))
    }

    func testTheOverallDeadlineWins() {
        let policy = ReconnectPolicy(maximumAttempts: 99, giveUpAfter: 10)
        XCTAssertTrue(policy.shouldAttempt(after: .networkLost, attempt: 2, elapsed: 9))
        XCTAssertFalse(policy.shouldAttempt(after: .networkLost, attempt: 2, elapsed: 11),
                       "staring at 'Reconnecting…' forever is worse than being told")
    }

    func testNonRetryableReasonsNeverAttempt() {
        let policy = ReconnectPolicy()
        XCTAssertFalse(policy.shouldAttempt(after: .authenticationFailed, attempt: 1, elapsed: 0))
        XCTAssertFalse(policy.shouldAttempt(after: .userLeft, attempt: 1, elapsed: 0))
    }

    // MARK: The sequence

    func testATransientDropSchedulesARetry() {
        var coordinator = ReconnectCoordinator(policy: ReconnectPolicy(baseDelay: 1, jitterFraction: 0))
        let status = coordinator.disconnected(reason: .networkLost, at: 0, randomFraction: 0)

        XCTAssertEqual(status, .waiting(attempt: 1, until: 1))
        XCTAssertTrue(coordinator.isReconnecting)
        XCTAssertEqual(coordinator.status.attemptNumber, 1)
    }

    func testAWrongRoomCodeGivesUpImmediately() {
        var coordinator = ReconnectCoordinator()
        let status = coordinator.disconnected(reason: .authenticationFailed, at: 0)

        XCTAssertEqual(status, .gaveUp(.authenticationFailed))
        XCTAssertFalse(coordinator.isReconnecting)
        XCTAssertEqual(coordinator.failureReason, .authenticationFailed)
    }

    func testTheAttemptFiresOnlyOnceItsTimeArrives() {
        var coordinator = ReconnectCoordinator(policy: ReconnectPolicy(baseDelay: 1, jitterFraction: 0))
        coordinator.disconnected(reason: .networkLost, at: 0, randomFraction: 0)

        XCTAssertFalse(coordinator.shouldAttemptNow(at: 0.5), "still inside the backoff")
        XCTAssertTrue(coordinator.shouldAttemptNow(at: 1.0))
        XCTAssertEqual(coordinator.status, .attempting(attempt: 1))
        XCTAssertFalse(coordinator.shouldAttemptNow(at: 1.1), "an attempt is already in flight")
    }

    func testFailuresEscalateThenGiveUp() {
        var coordinator = ReconnectCoordinator(
            policy: ReconnectPolicy(maximumAttempts: 3, baseDelay: 1, maximumDelay: 100, jitterFraction: 0, giveUpAfter: 1000)
        )
        coordinator.disconnected(reason: .networkLost, at: 0, randomFraction: 0)

        XCTAssertTrue(coordinator.shouldAttemptNow(at: 1))
        XCTAssertEqual(coordinator.attemptFailed(at: 1, randomFraction: 0), .waiting(attempt: 2, until: 3))

        XCTAssertTrue(coordinator.shouldAttemptNow(at: 3))
        XCTAssertEqual(coordinator.attemptFailed(at: 3, randomFraction: 0), .waiting(attempt: 3, until: 7))

        XCTAssertTrue(coordinator.shouldAttemptNow(at: 7))
        XCTAssertEqual(coordinator.attemptFailed(at: 7, randomFraction: 0), .gaveUp(.networkLost),
                       "out of attempts")
        XCTAssertFalse(coordinator.isReconnecting)
    }

    func testGivesUpAsSoonAsTheNextAttemptWouldMissTheDeadline() {
        // The next attempt is validated against when it would *run*. Scheduling
        // one the deadline will reject on arrival means the player watches
        // "Reconnecting…" for the whole backoff to learn something already
        // known.
        var coordinator = ReconnectCoordinator(
            policy: ReconnectPolicy(maximumAttempts: 99, baseDelay: 5, maximumDelay: 100, jitterFraction: 0, giveUpAfter: 6)
        )
        coordinator.disconnected(reason: .networkLost, at: 0, randomFraction: 0)
        XCTAssertTrue(coordinator.shouldAttemptNow(at: 5))

        // Attempt 2 would land at t=15, past the 6s deadline — so give up now,
        // at t=5, not at t=15.
        XCTAssertEqual(coordinator.attemptFailed(at: 5, randomFraction: 0), .gaveUp(.networkLost))
        XCTAssertEqual(coordinator.failureReason, .networkLost)
    }

    func testSucceedingClearsTheBackoff() {
        var coordinator = ReconnectCoordinator(policy: ReconnectPolicy(baseDelay: 1, maximumDelay: 100, jitterFraction: 0))
        coordinator.disconnected(reason: .networkLost, at: 0, randomFraction: 0)
        XCTAssertTrue(coordinator.shouldAttemptNow(at: 1))
        coordinator.attemptFailed(at: 1, randomFraction: 0)
        coordinator.succeeded()

        XCTAssertEqual(coordinator.status, .idle)

        // A later drop starts over at attempt one, not at the old backoff.
        XCTAssertEqual(
            coordinator.disconnected(reason: .networkLost, at: 100, randomFraction: 0),
            .waiting(attempt: 1, until: 101)
        )
    }

    func testCancellingStops() {
        var coordinator = ReconnectCoordinator()
        coordinator.disconnected(reason: .networkLost, at: 0)
        coordinator.cancel()

        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertFalse(coordinator.shouldAttemptNow(at: 1000))
    }

    func testReturningToTheForegroundRetriesImmediately() {
        // The iPad has just regained its network. Waiting out a backoff that
        // was scheduled while it was asleep is delay the player can see.
        var coordinator = ReconnectCoordinator(policy: ReconnectPolicy(baseDelay: 8, maximumDelay: 8, jitterFraction: 0))
        coordinator.disconnected(reason: .networkLost, at: 0, randomFraction: 0)
        XCTAssertFalse(coordinator.shouldAttemptNow(at: 2))

        coordinator.retryImmediately(at: 2)
        XCTAssertTrue(coordinator.shouldAttemptNow(at: 2))
    }

    func testRetryImmediatelyDoesNothingWhenNotWaiting() {
        var coordinator = ReconnectCoordinator()
        coordinator.retryImmediately(at: 5)
        XCTAssertEqual(coordinator.status, .idle, "nothing to bring forward")
    }

    // MARK: Display

    func testProgressTellsThePlayerWhereTheyAre() {
        var coordinator = ReconnectCoordinator(policy: ReconnectPolicy(maximumAttempts: 5))
        XCTAssertNil(coordinator.progressDescription, "nothing to say while connected")

        coordinator.disconnected(reason: .networkLost, at: 0)
        XCTAssertEqual(coordinator.progressDescription, "Reconnecting… (1 of 5)")
    }

    func testAHostNeverReconnects() {
        // There is nothing for a host to reconnect *to*.
        var coordinator = ReconnectCoordinator(policy: .none)
        XCTAssertEqual(coordinator.disconnected(reason: .networkLost, at: 0), .gaveUp(.networkLost))
    }
}
