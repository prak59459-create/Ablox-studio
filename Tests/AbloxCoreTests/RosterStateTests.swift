import XCTest
@testable import AbloxCore

/// The roster as one device sees it — and the two position bugs reported from
/// real iPads: the host never saw a joined player move, and a joining player
/// ignored the spawn point the host gave them.
final class RosterStateTests: XCTestCase {

    private let me = PeerID()
    private let host = PeerID()
    private let guest = PeerID()

    private func snapshot(_ peer: PeerID, at position: Vec3 = .zero, score: Int = 0, name: String = "P") -> PlayerSnapshot {
        var profile = AvatarProfile.default
        profile.displayName = name
        return PlayerSnapshot(peerID: peer, profile: profile, position: position, score: score)
    }

    private func transform(_ peer: PeerID, to position: Vec3) -> PlayerTransformPayload {
        PlayerTransformPayload(peerID: peer, position: position, yawDegrees: 90, velocity: Vec3(1, 0, 0), isGrounded: false)
    }

    // MARK: The host seeing others move

    func testAnotherPlayersMovementIsApplied() {
        // Bug 1, from the host's side. The host is "me" here; the guest walks.
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(me), snapshot(guest, at: Vec3(3, 0, 0))])

        state.apply(transform(guest, to: Vec3(10, 2, -4)))

        XCTAssertEqual(state.player(guest)?.position, Vec3(10, 2, -4),
                       "a joined player must move on the host's screen")
        XCTAssertEqual(state.player(guest)?.yawDegrees, 90)
        XCTAssertEqual(state.player(guest)?.isGrounded, false)
    }

    func testMovementKeepsNameAvatarAndScore() {
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(guest, score: 40, name: "Mika")])
        state.apply(transform(guest, to: Vec3(1, 1, 1)))

        XCTAssertEqual(state.player(guest)?.score, 40)
        XCTAssertEqual(state.player(guest)?.profile.displayName, "Mika")
    }

    func testOurOwnEchoIsIgnored() {
        // The local simulation is the authority on where we are; our own
        // transform coming back must not drag us to where we were.
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(me, at: Vec3(5, 0, 5))])
        state.apply(transform(me, to: Vec3(-100, 0, 0)))

        XCTAssertEqual(state.localPlayer?.position, Vec3(5, 0, 5))
    }

    // MARK: Order independence

    func testMovementThatArrivesBeforeTheRosterIsNotLost() {
        // The roster and the transforms come by different paths and reach the
        // main actor in no guaranteed order. A newcomer's first steps landing
        // first must not leave them frozen until they next move.
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(me)])

        state.apply(transform(guest, to: Vec3(7, 0, 7)))
        XCTAssertNil(state.player(guest), "not introduced yet")

        state.replace(with: [snapshot(me), snapshot(guest, at: .zero)])
        XCTAssertEqual(state.player(guest)?.position, Vec3(7, 0, 7),
                       "the held movement should apply the moment they appear")
    }

    func testOnlyTheNewestEarlyMovementIsKept() {
        var state = RosterState(localPeerID: me)
        state.apply(transform(guest, to: Vec3(1, 0, 0)))
        state.apply(transform(guest, to: Vec3(2, 0, 0)))
        state.replace(with: [snapshot(guest)])

        XCTAssertEqual(state.player(guest)?.position, Vec3(2, 0, 0))
    }

    func testEarlyMovementForSomeoneWhoNeverArrivesIsDropped() {
        // Otherwise every departure mid-join would leak an entry.
        var state = RosterState(localPeerID: me)
        state.apply(transform(guest, to: Vec3(1, 0, 0)))
        state.replace(with: [snapshot(me)])
        state.replace(with: [snapshot(me), snapshot(guest)])

        XCTAssertEqual(state.player(guest)?.position, .zero,
                       "a stale early transform must not resurface in a later session")
    }

    // MARK: Rosters do not rewind motion

    func testANewRosterDoesNotRewindPlayersAlreadyMoving() {
        // Rosters are sent on join, leave and score changes, so their
        // positions are older than the transforms already held. Taking them
        // would make every avatar hitch backwards whenever anyone scored.
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(me), snapshot(guest, at: .zero)])
        state.apply(transform(guest, to: Vec3(20, 0, 0)))

        state.replace(with: [snapshot(me), snapshot(guest, at: Vec3(15, 0, 0), score: 10)])

        XCTAssertEqual(state.player(guest)?.position, Vec3(20, 0, 0), "motion comes from transforms")
        XCTAssertEqual(state.player(guest)?.score, 10, "everything else comes from the roster")
    }

    func testAPlayerWhoLeftIsRemoved() {
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(me), snapshot(guest)])
        state.replace(with: [snapshot(me)])
        XCTAssertNil(state.player(guest))
        XCTAssertEqual(state.otherPlayers.count, 0)
    }

    // MARK: Spawn placement

    func testTheJoiningPlayerIsPlacedWhereTheHostPutThem() {
        // Bug 2. The host gives each player their own spawn point; the client
        // used to ignore it and start at spawn zero, on top of the host.
        var state = RosterState(localPeerID: me)
        let events = state.replace(with: [
            snapshot(host, at: Vec3(0, 0, 0)),
            snapshot(me, at: Vec3(3, 0, 0))
        ])

        XCTAssertEqual(events, [.placeLocalPlayer(at: Vec3(3, 0, 0))])
    }

    func testPlacementHappensOnceNotOnEveryRoster() {
        // A later roster — someone scored, someone joined — must not yank the
        // player back to the start from wherever they have walked to.
        var state = RosterState(localPeerID: me)
        XCTAssertFalse(state.replace(with: [snapshot(me, at: Vec3(3, 0, 0))]).isEmpty)
        XCTAssertTrue(state.replace(with: [snapshot(me, at: Vec3(3, 0, 0)), snapshot(guest)]).isEmpty)
        XCTAssertTrue(state.replace(with: [snapshot(me, at: Vec3(3, 0, 0), score: 5)]).isEmpty)
    }

    func testNoPlacementUntilTheLocalPlayerIsInTheRoster() {
        var state = RosterState(localPeerID: me)
        XCTAssertTrue(state.replace(with: [snapshot(host)]).isEmpty,
                      "a roster without us has nowhere to put us")
        XCTAssertEqual(state.replace(with: [snapshot(host), snapshot(me, at: Vec3(1, 0, 1))]),
                       [.placeLocalPlayer(at: Vec3(1, 0, 1))])
    }

    func testResetPlacesTheLocalPlayerAgainInTheNextSession() {
        var state = RosterState(localPeerID: me)
        state.replace(with: [snapshot(me, at: Vec3(3, 0, 0))])
        state.reset()

        XCTAssertTrue(state.players.isEmpty)
        XCTAssertEqual(state.replace(with: [snapshot(me, at: Vec3(6, 0, 0))]),
                       [.placeLocalPlayer(at: Vec3(6, 0, 0))])
    }

    // MARK: Against the host's own spawn assignment

    func testTheHostAndTheJoinerAgreeOnDifferentSpawns() {
        // End to end with the real EventMachine the host runs: two players,
        // two different spawn points, and the joiner is told theirs.
        var world = WorldDocument(name: "Two pads")
        world.blocks = [
            BlockData.preset(.spawn, at: Vec3(-4, 0.1, 0)),
            BlockData.preset(.spawn, at: Vec3(4, 0.1, 0))
        ]

        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(host, name: "Host"))
        machine.addPlayer(snapshot(me, name: "Joiner"))

        var joinerView = RosterState(localPeerID: me)
        let events = joinerView.replace(with: machine.roster)

        guard case let .placeLocalPlayer(at: placed)? = events.first else {
            return XCTFail("the joiner was not placed")
        }
        XCTAssertEqual(placed, machine.player(me)?.position)
        XCTAssertNotEqual(placed, machine.player(host)?.position,
                          "the joiner must not start on top of the host")
    }
}
