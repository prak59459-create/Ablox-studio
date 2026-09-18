import XCTest
@testable import AbloxCore

/// Task 8 — dead reckoning on the transform channel.
final class TransformPublisherTests: XCTestCase {

    private let peer = PeerID()

    private func snapshot(
        position: Vec3 = .zero,
        yaw: Float = 0,
        velocity: Vec3 = .zero,
        grounded: Bool = true
    ) -> PlayerSnapshot {
        PlayerSnapshot(peerID: peer, position: position, yawDegrees: yaw, velocity: velocity, isGrounded: grounded)
    }

    func testTheFirstSnapshotIsAlwaysSent() {
        var publisher = TransformPublisher()
        XCTAssertTrue(publisher.shouldPublish(snapshot(), at: 0), "peers start knowing nothing")
    }

    func testAStationaryPlayerIsNotRepublished() {
        var publisher = TransformPublisher()
        let still = snapshot()
        XCTAssertTrue(publisher.shouldPublish(still, at: 0))

        // A second of standing around at 20 Hz.
        var sends = 0
        for tick in 1...20 where publisher.shouldPublish(still, at: Double(tick) / 20) {
            sends += 1
        }
        XCTAssertLessThanOrEqual(sends, 1, "standing still should cost at most the keepalive")
    }

    func testKeepaliveStillFires() {
        var publisher = TransformPublisher()
        let still = snapshot()
        XCTAssertTrue(publisher.shouldPublish(still, at: 0))
        XCTAssertFalse(publisher.shouldPublish(still, at: 0.5))
        XCTAssertTrue(publisher.shouldPublish(still, at: 1.1),
                      "a peer must hear something within maximumSilence")
    }

    func testSteadyRunningIsPredictedRatherThanResent() {
        // The whole point of dead reckoning: a player moving at a constant
        // velocity is exactly what peers already extrapolate, so it needs
        // almost no packets.
        var publisher = TransformPublisher()
        let velocity = Vec3(5, 0, 0)
        var position = Vec3.zero

        XCTAssertTrue(publisher.shouldPublish(snapshot(position: position, velocity: velocity), at: 0))

        var sends = 0
        for tick in 1...40 {
            let t = Double(tick) / 20
            position = velocity * Float(t)
            if publisher.shouldPublish(snapshot(position: position, velocity: velocity), at: t) {
                sends += 1
            }
        }
        // Two seconds of running: only the keepalives.
        XCTAssertLessThanOrEqual(sends, 3, "constant-velocity motion should be mostly predicted, got \(sends)")
    }

    func testChangingDirectionSendsImmediately() {
        var publisher = TransformPublisher()
        XCTAssertTrue(publisher.shouldPublish(snapshot(velocity: Vec3(5, 0, 0)), at: 0))
        XCTAssertFalse(publisher.shouldPublish(snapshot(position: Vec3(0.25, 0, 0), velocity: Vec3(5, 0, 0)), at: 0.05))
        XCTAssertTrue(
            publisher.shouldPublish(snapshot(position: Vec3(0.5, 0, 0), velocity: Vec3(-5, 0, 0)), at: 0.1),
            "reversing must not wait for the position threshold"
        )
    }

    func testJumpingSendsImmediately() {
        var publisher = TransformPublisher()
        XCTAssertTrue(publisher.shouldPublish(snapshot(grounded: true), at: 0))
        XCTAssertTrue(
            publisher.shouldPublish(snapshot(velocity: Vec3(0, 6, 0), grounded: false), at: 0.06),
            "leaving the ground changes how the avatar is drawn"
        )
    }

    func testTurningOnTheSpotSends() {
        var publisher = TransformPublisher()
        XCTAssertTrue(publisher.shouldPublish(snapshot(yaw: 0), at: 0))
        XCTAssertFalse(publisher.shouldPublish(snapshot(yaw: 0.5), at: 0.06), "sub-threshold wobble")
        XCTAssertTrue(publisher.shouldPublish(snapshot(yaw: 40), at: 0.12))
    }

    func testYawComparisonTakesTheShortWayRound() {
        var publisher = TransformPublisher()
        XCTAssertTrue(publisher.shouldPublish(snapshot(yaw: 179), at: 0))
        // 179° -> -179.5° is a 1.5° turn, not a 358.5° one. Deliberately
        // under the 2° threshold: the point here is the wrap arithmetic, not
        // where the threshold sits.
        XCTAssertFalse(
            publisher.shouldPublish(snapshot(yaw: -179.5), at: 0.06),
            "crossing the wrap point is a small turn, not a huge one"
        )
        // And a genuinely large turn across the same boundary does send.
        XCTAssertTrue(publisher.shouldPublish(snapshot(yaw: -90), at: 0.12))
    }

    func testTheRateCeilingIsRespected() {
        var publisher = TransformPublisher()
        XCTAssertTrue(publisher.shouldPublish(snapshot(), at: 0))
        // Teleport far away, but only a moment later.
        XCTAssertFalse(
            publisher.shouldPublish(snapshot(position: Vec3(500, 0, 0)), at: 0.001),
            "even a huge change waits for the rate ceiling"
        )
        XCTAssertTrue(publisher.shouldPublish(snapshot(position: Vec3(500, 0, 0)), at: 0.2))
    }

    func testResetMakesTheNextTickSend() {
        var publisher = TransformPublisher()
        let still = snapshot()
        XCTAssertTrue(publisher.shouldPublish(still, at: 0))
        XCTAssertFalse(publisher.shouldPublish(still, at: 0.1))

        // After a reconnect the new peer knows nothing.
        publisher.reset()
        XCTAssertTrue(publisher.shouldPublish(still, at: 0.15))
    }

    func testSuppressionRateIsMeasured() {
        var publisher = TransformPublisher()
        let still = snapshot()
        for tick in 0...40 {
            _ = publisher.shouldPublish(still, at: Double(tick) / 20)
        }
        XCTAssertGreaterThan(publisher.suppressionRate, 0.8,
                             "an idle player should suppress the overwhelming majority of ticks")
        XCTAssertEqual(publisher.consideredCount, 41)
        XCTAssertGreaterThan(publisher.consideredCount, publisher.sentCount)
    }

    func testPredictedPositionExtrapolatesLastKnownVelocity() {
        var publisher = TransformPublisher()
        XCTAssertNil(publisher.predictedPosition(after: 1), "nothing sent yet, nothing to predict")

        _ = publisher.shouldPublish(snapshot(position: .zero, velocity: Vec3(4, 0, 0)), at: 0)
        let predicted = publisher.predictedPosition(after: 0.5)
        XCTAssertEqual(predicted?.x ?? 0, 2, accuracy: 1e-4)
    }

    func testConservativeThresholdsSendLess() {
        func sends(with thresholds: TransformPublisher.Thresholds) -> Int {
            var publisher = TransformPublisher(thresholds: thresholds)
            var count = 0
            for tick in 0...60 {
                let t = Double(tick) / 20
                // A jittery walk: small, constant course corrections.
                let wobble = Float(sin(t * 8)) * 0.4
                let snap = snapshot(position: Vec3(Float(t) * 2, 0, wobble), velocity: Vec3(2, 0, wobble))
                if publisher.shouldPublish(snap, at: t) { count += 1 }
            }
            return count
        }
        XCTAssertLessThan(sends(with: .conservative), sends(with: .default))
    }

    func testProtocolRateMatchesTheBrief() {
        // The spec calls for 20 Hz; the publisher only ever sends below it.
        XCTAssertEqual(AbloxProtocol.transformHz, 20)
    }
}
