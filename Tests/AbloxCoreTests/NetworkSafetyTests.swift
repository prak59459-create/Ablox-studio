import XCTest
@testable import AbloxCore

final class NetworkSafetyTests: XCTestCase {

    func testSteadyPlayIsNeverDropped() {
        var budget = PacketBudget()
        var time = 0.0
        for _ in 0..<2_000 {
            time += 1.0 / 20
            XCTAssertEqual(budget.admit(.playerTransform, at: time), .allow)
        }
    }

    func testABurstIsAbsorbedAndAFloodIsCut() {
        var budget = PacketBudget()
        // Five quick chat lines are fine; the rest of a spam burst is dropped.
        let verdicts = (0..<20).map { _ in budget.admit(.chat, at: 1) }
        XCTAssertEqual(verdicts.prefix(6).filter { $0 == .allow }.count, 6)
        XCTAssertEqual(verdicts.last, .drop)
        // It refills with time.
        XCTAssertEqual(budget.admit(.chat, at: 3), .allow)

        var flood = PacketBudget()
        var last = PacketBudget.Verdict.allow
        for i in 0..<2_000 { last = flood.admit(.playerInput, at: 5 + Double(i) * 0.001) }
        XCTAssertEqual(last, .disconnect)
    }

    func testRepeatedFailuresAreTurnedAwayForAWhile() {
        var limiter = AttemptLimiter()
        for i in 0..<AttemptLimiter.maximumFailures { limiter.recordFailure("10.0.0.9", at: Double(i)) }
        XCTAssertTrue(limiter.isBanned("10.0.0.9", at: 20))
        XCTAssertFalse(limiter.isBanned("10.0.0.8", at: 20))
        XCTAssertFalse(limiter.isBanned("10.0.0.9", at: 20 + AttemptLimiter.banDuration))
    }

    func testImpossibleTransformsAreRefused() {
        let peer = PeerID()
        XCTAssertTrue(PlayerTransformPayload(peerID: peer, position: Vec3(10, 2, -30), yawDegrees: 90).isPlausible)
        XCTAssertFalse(PlayerTransformPayload(peerID: peer, position: Vec3(.nan, 0, 0), yawDegrees: 0).isPlausible)
        XCTAssertFalse(PlayerTransformPayload(peerID: peer, position: Vec3(0, 1e9, 0), yawDegrees: 0).isPlausible)
        XCTAssertFalse(PlayerTransformPayload(peerID: peer, position: .zero, yawDegrees: .infinity).isPlausible)
        XCTAssertFalse(PlayerTransformPayload(peerID: peer, position: .zero, yawDegrees: 0, velocity: Vec3(1e6, 0, 0)).isPlausible)
    }

    func testAGuestsProfileIsMadeSafeToShow() {
        var profile = AvatarProfile.default
        profile.displayName = "  Mika\n\u{0007}" + String(repeating: "x", count: 100)
        profile.height = 50
        profile.bodyColor = ColorRGBA(r: .nan, g: 5, b: -1)
        let safe = profile.sanitizedForNetwork()
        XCTAssertFalse(safe.displayName.contains("\n"))
        XCTAssertLessThanOrEqual(safe.displayName.count, AvatarProfile.maximumNameLength)
        XCTAssertTrue(safe.displayName.hasPrefix("Mika"))
        XCTAssertEqual(safe.height, AvatarProfile.chosenHeightRange.upperBound)
        XCTAssertEqual(safe.bodyColor, ColorRGBA(r: 0, g: 1, b: 0))

        profile.displayName = "\n\t "
        XCTAssertEqual(profile.sanitizedForNetwork().displayName, "Player")
    }

    func testChatCarriesTheVerifiedSenderAndOlderPayloadsStillRead() throws {
        let id = PeerID()
        let data = try JSONEncoder().encode(ChatPayload(senderName: "Ren", text: "hi", senderID: id))
        XCTAssertEqual(try JSONDecoder().decode(ChatPayload.self, from: data).senderID, id)
        let old = try JSONDecoder().decode(ChatPayload.self, from: Data(#"{"senderName":"Ren","text":"hi"}"#.utf8))
        XCTAssertNil(old.senderID)
    }
}

/// `block` and `blocks` answer from a kept lookup; it must never go stale.
final class BlockLookupTests: RuntimeTestCase {

    func testLookupsFollowRenamesNewBlocksAndDeletions() {
        var world = WorldDocument(name: "Arena")
        world.blocks.append(BlockData(name: "Door", tags: ["Exit"]))
        world.blocks.append(BlockData(name: "Door", tags: ["exit"]))
        let game = game(#"""
        on start()
          print("first=" + (block("Door") != nil) + " any-case=" + (block("door") != nil) + " exits=" + len(blocks("EXIT")))
          let d = block("Door")
          d.x = 5
          print("moved still found=" + (block("Door") != nil))
          d.name = "Gate"
          d.tags = ["open"]
          print("renamed gate=" + (block("Gate") != nil) + " doors=" + (block("Door") != nil) + " exits=" + len(blocks("exit")) + " open=" + len(blocks("open")))
          let c = create_block({name: "Coin", tags: ["coin"]})
          print("coins=" + len(blocks("coin")) + " coin=" + (block("Coin") != nil))
          c.destroy()
          print("after destroy coins=" + len(blocks("coin")) + " coin=" + (block("Coin") == nil))
          let first = block("Gate")
          for i in 1 to 3 do create_block({name: "Gate", tags: ["open"]}) end
          print("first gate kept=" + (block("Gate") == first) + " open=" + len(blocks("open")) + " in order=" + (blocks("open")[1] == first))
        end
        """#, world: world)
        game.handle(.roundStarted)
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        XCTAssertEqual(game.drainOutput(), [
            "first=true any-case=true exits=2",
            "moved still found=true",
            "renamed gate=true doors=true exits=1 open=1",
            "coins=1 coin=true",
            "after destroy coins=0 coin=true",
            "first gate kept=true open=4 in order=true"
        ])
    }
}
