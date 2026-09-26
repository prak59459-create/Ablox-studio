import XCTest
@testable import AbloxCore

final class GestureTests: RuntimeTestCase {

    private func gestures(_ effects: [GameRuntime.Effect]) -> [(PeerID, String)] {
        effects.compactMap { effect in
            guard effect.targetPeerID == nil, case let .script(.gesture(speaker, wire)) = effect.action else { return nil }
            return (speaker, wire)
        }
    }

    func testWireNamesRoundTripAndUnknownOnesAreRefused() {
        XCTAssertEqual(Gesture(wire: "wave"), .emote(.wave))
        XCTAssertEqual(Gesture(wire: "stamp:🎉"), .stamp("🎉"))
        XCTAssertEqual(Gesture(wire: "stamp:🎉")?.wire, "stamp:🎉")
        XCTAssertNil(Gesture(wire: "moonwalk"))
        XCTAssertNil(Gesture(wire: "stamp:hello"), "only the listed emoji, not any text")
        for emote in Emote.allCases { XCTAssertEqual(Gesture(wire: emote.rawValue), .emote(emote)) }
    }

    func testAGestureGoesToEveryoneAndIsRateLimited() {
        let game = game(nil)
        startWithBoth(game)
        let first = game.handle(.gesture("wave"), from: alice, at: 1)
        XCTAssertEqual(gestures(first).map(\.1), ["wave"])
        XCTAssertEqual(gestures(first).first?.0, alice)
        XCTAssertTrue(gestures(game.handle(.gesture("dance"), from: alice, at: 1.3)).isEmpty, "too soon")
        XCTAssertEqual(gestures(game.handle(.gesture("dance"), from: alice, at: 2)).map(\.1), ["dance"])
        XCTAssertTrue(gestures(game.handle(.gesture("rm -rf"), from: bob, at: 3)).isEmpty)
    }

    func testScriptsHearAndMakeGestures() {
        let game = game(#"""
        on emote(p, name)
          print(p.name + " " + name)
          if name == "wave" then p.emote("bow") end
        end
        """#)
        startWithBoth(game)
        let effects = game.handle(.gesture("wave"), from: bob, at: 1)
        XCTAssertEqual(game.drainOutput(), ["Bob wave"])
        XCTAssertEqual(gestures(effects).map(\.1), ["wave", "bow"])
        XCTAssertEqual(game.drainErrors().map(\.message), [])
    }

    func testAScriptAskingForAMadeUpEmoteGetsAClearError() {
        let game = game(#"""
        on join(p)
          p.emote("backflip")
        end
        """#)
        startWithBoth(game)
        let errors = game.drainErrors().map(\.message)
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.allSatisfy { $0.contains("backflip") }, "\(errors)")
    }
}
