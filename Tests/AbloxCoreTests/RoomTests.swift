import XCTest
@testable import AbloxCore

final class RoomTests: XCTestCase {

    private func roundTrip(_ message: RoomMessage) throws -> RoomMessage {
        try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(message))
    }

    // MARK: Messages

    func testEveryRoomMessageSurvivesTheWire() throws {
        let a = PeerID(), b = PeerID()
        var state = RoomState()
        state.ready = [a]
        state.quieted = [b]
        state.needsApproval = true
        state.poll = Poll(question: "Play again?", options: ["Yes", "No"], closesAt: 30)
        let move = HostMove(newHost: b, newHostName: "Mika", roomCode: "ABCDEF", isPublic: true, capacity: 8, needsApproval: false)
        let messages: [RoomMessage] = [
            .ready(true), .vote(poll: UUID(), choice: 1), .whisper(to: a, text: "hi"), .state(state),
            .whispered(from: a, name: "Aki", text: "psst"), .waitingForHost, .refused, .removed, .moving(move)
        ]
        for message in messages {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testLongWhispersAreCutOnArrival() throws {
        let long = String(repeating: "a", count: 5_000)
        guard case let .whisper(_, text) = try roundTrip(.whisper(to: PeerID(), text: long)) else { return XCTFail() }
        XCTAssertEqual(text.count, AbloxProtocol.maxChatLength)
    }

    func testAnUnknownMessageIsRefusedNotMisread() {
        let data = Data(#"{"type":"teleportEveryone"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RoomMessage.self, from: data))
    }

    func testAnOlderRoomStateStillReads() throws {
        let state = try JSONDecoder().decode(RoomState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.allowsWarp)
        XCTAssertFalse(state.needsApproval)
        XCTAssertTrue(state.ready.isEmpty)
    }

    func testReadyCountOnlyCountsPeoplePresent() {
        let a = PeerID(), b = PeerID(), gone = PeerID()
        var state = RoomState()
        state.ready = [a, gone]
        XCTAssertEqual(state.readyCount(of: [a, b]), 1)
    }

    // MARK: Votes

    func testAPollNeedsAQuestionAndTwoToFourAnswers() {
        XCTAssertNil(Poll(question: "Pick", options: ["One"], closesAt: 1))
        XCTAssertNil(Poll(question: "  ", options: ["A", "B"], closesAt: 1))
        XCTAssertNil(Poll(question: "Pick", options: ["A", "B", "C", "D", "E"], closesAt: 1))
        XCTAssertEqual(Poll(question: "Pick", options: ["A", " ", "B"], closesAt: 1)?.options, ["A", "B"])
    }

    func testVotingChangingAndClosing() {
        let a = PeerID(), b = PeerID(), c = PeerID()
        var poll = Poll(question: "Play again?", options: ["Yes", "No"], closesAt: 30)!
        XCTAssertTrue(poll.vote(a, choice: 0))
        XCTAssertTrue(poll.vote(b, choice: 1))
        XCTAssertNil(poll.winner, "a tie has no winner")
        XCTAssertTrue(poll.vote(b, choice: 0), "changing your mind replaces your vote")
        XCTAssertFalse(poll.vote(c, choice: 7))
        XCTAssertEqual(poll.tally, [2, 0])
        XCTAssertEqual(poll.winner, 0)
        XCTAssertFalse(poll.closeIfDue(at: 29))
        XCTAssertTrue(poll.closeIfDue(at: 30))
        XCTAssertFalse(poll.closeIfDue(at: 31), "closes once")
        XCTAssertFalse(poll.vote(c, choice: 1), "too late")
    }

    func testNoVotesNoWinner() {
        XCTAssertNil(Poll(question: "Q", options: ["A", "B"], closesAt: 1)?.winner)
    }

    func testPresetsAreAllValid() {
        for preset in Poll.presets {
            XCTAssertNotNil(Poll(question: preset.question, options: preset.options, closesAt: 1))
        }
    }

    // MARK: Teams

    func testShuffledTeamsAreEvenAndRepeatable() {
        let players = (0..<7).map { _ in PeerID() }
        let teams = TeamPicker.shuffled(players, teams: 2, seed: 42)
        XCTAssertEqual(teams.count, 7)
        let red = teams.values.filter { $0 == "Red" }.count
        XCTAssertTrue((3...4).contains(red))
        XCTAssertEqual(TeamPicker.shuffled(players, teams: 2, seed: 42), teams)
        XCTAssertEqual(Set(TeamPicker.shuffled(players, teams: 9, seed: 1).values).count, 4, "at most four teams")
    }

    func testTappingCyclesThroughTheTeams() {
        XCTAssertEqual(TeamPicker.next(after: "", teams: 3), "Red")
        XCTAssertEqual(TeamPicker.next(after: "Red", teams: 3), "Blue")
        XCTAssertEqual(TeamPicker.next(after: "Green", teams: 3), "")
        XCTAssertEqual(TeamPicker.colorHex(for: "Blue"), "#3B82F6")
        XCTAssertNil(TeamPicker.colorHex(for: "Pirates"))
    }

    func testTheHostsTeamsReachTheRosterAndOutlastARound() {
        let world = WorldDocument.starter(named: "Teams", author: "Test")
        let runtime = GameRuntime(world: world)
        let a = PeerID(), b = PeerID()
        _ = runtime.addPlayer(PlayerSnapshot(peerID: a))
        _ = runtime.addPlayer(PlayerSnapshot(peerID: b))
        _ = runtime.handle(.roundStarted)
        runtime.assignTeams([a: "Red", b: "Blue"])
        XCTAssertTrue(runtime.takeRosterChange())
        XCTAssertEqual(runtime.roster.first { $0.peerID == a }?.team, "Red")
        _ = runtime.handle(.roundStarted)
        XCTAssertEqual(runtime.roster.first { $0.peerID == b }?.team, "Blue")
        runtime.assignTeams([a: ""])
        XCTAssertEqual(runtime.roster.first { $0.peerID == a }?.team, "")
    }

    func testATeamTravelsInTheRosterAndAnOldRosterStillReads() throws {
        var player = PlayerSnapshot(peerID: PeerID())
        player.team = "Green"
        let back = try JSONDecoder().decode(PlayerSnapshot.self, from: JSONEncoder().encode(player))
        XCTAssertEqual(back.team, "Green")
        let plain = String(decoding: try JSONEncoder().encode(PlayerSnapshot(peerID: PeerID())), as: UTF8.self)
        XCTAssertFalse(plain.contains("team"))
    }

    // MARK: Handing over

    func testTheLongestHereTakesOverAndNeverAnNPC() {
        let host = PeerID(), npc = PeerID(), first = PeerID(), second = PeerID()
        let roster = [PlayerSnapshot(peerID: host), PlayerSnapshot(peerID: npc, isNPC: true),
                      PlayerSnapshot(peerID: first), PlayerSnapshot(peerID: second)]
        XCTAssertEqual(HostMove.successor(in: roster, leavingHost: host)?.peerID, first)
        XCTAssertNil(HostMove.successor(in: [PlayerSnapshot(peerID: host)], leavingHost: host))
    }

    // MARK: Room tags

    func testRoomTagsRecogniseFriendsFromTheAdvertisement() {
        let friend = PeerID(), stranger = PeerID()
        let tag = RoomTag(players: [friend, PeerID()])
        let read = RoomTag(text: tag.text + ",nothex!!,ABCDEF0123")
        XCTAssertTrue(read.contains(friend))
        XCTAssertFalse(read.contains(stranger))
        XCTAssertEqual(read.shortIDs.count, 2, "junk is dropped")
        XCTAssertEqual(RoomTag.short(friend).count, RoomTag.length)
    }

    // MARK: Join tickets

    func testATicketRoundTripsAsText() {
        let ticket = JoinTicket(host: "192.168.1.20", port: 52_001, salt: String(repeating: "ab", count: 16),
                                code: "abc def", world: "Sky & Sea")!
        XCTAssertEqual(ticket.code, "ABCDEF")
        let read = JoinTicket(text: ticket.text)
        XCTAssertEqual(read, ticket)
        XCTAssertEqual(read?.world, "Sky & Sea")
        XCTAssertNotNil(JoinTicket(host: "fe80::1%en0", port: 1, salt: "0123456789abcdef", code: "ABCDEF", world: ""))
    }

    func testBadTicketsAreRefused() {
        let salt = "0123456789abcdef"
        XCTAssertNil(JoinTicket(text: "https://example.com/?h=1.2.3.4&p=1&s=\(salt)&c=ABCDEF"))
        XCTAssertNil(JoinTicket(text: "ablox:join?h=1.2.3.4&p=0&s=\(salt)&c=ABCDEF"))
        XCTAssertNil(JoinTicket(text: "ablox:join?h=1.2.3.4&p=80&s=zz&c=ABCDEF"))
        XCTAssertNil(JoinTicket(text: "ablox:join?h=1.2.3.4&p=80&s=\(salt)&c=AB"))
        XCTAssertNil(JoinTicket(text: "ablox:join?h=a/b&p=80&s=\(salt)&c=ABCDEF"))
    }

    // MARK: Friends

    func testMeetingPeopleRemembersThemOnceAVisit() {
        let me = PeerID(), aki = PeerID()
        var book = SocialBook()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let players = [PlayerSnapshot(peerID: me), PlayerSnapshot(peerID: aki, profile: AvatarProfile(displayName: "Aki")),
                       PlayerSnapshot(peerID: PeerID(), isNPC: true)]
        book.met(players, game: "Obby", localPeerID: me, at: start)
        book.met(players, game: "Obby", localPeerID: me, at: start.addingTimeInterval(60))
        XCTAssertEqual(book.recent.count, 1, "not me, not the NPC")
        XCTAssertEqual(book.recent[0].timesMet, 1, "the same visit")
        book.met(players, game: "Race", localPeerID: me, at: start.addingTimeInterval(3_600))
        XCTAssertEqual(book.recent[0].timesMet, 2)
        XCTAssertEqual(book.recent[0].lastGame, "Race")
    }

    func testFriendsBlocksAndRooms() {
        let aki = PeerID(), ren = PeerID()
        var book = SocialBook()
        XCTAssertTrue(book.addFriend(aki, name: "Aki"))
        XCTAssertTrue(book.isFriend(aki))
        book.block(aki, name: "Aki")
        XCTAssertFalse(book.isFriend(aki), "blocking ends a friendship")
        XCTAssertTrue(book.isBlocked(aki))
        XCTAssertFalse(book.addFriend(aki, name: "Aki"), "no friending someone blocked")
        book.unblock(aki)
        XCTAssertTrue(book.addFriend(ren, name: "Ren"))
        let room = RoomTag(players: [ren])
        XCTAssertEqual(book.friends(in: room).map(\.id), [ren])
        XCTAssertTrue(book.blocked(in: room).isEmpty)
    }

    func testTheRecentListIsBounded() {
        var book = SocialBook()
        let me = PeerID()
        for _ in 0..<(SocialBook.keptRecent + 5) {
            book.met([PlayerSnapshot(peerID: PeerID())], game: "G", localPeerID: me)
        }
        XCTAssertEqual(book.recent.count, SocialBook.keptRecent)
    }

    func testReportsKeepTheRecentChatAndReadAsText() {
        let lines = (1...50).map { "Aki: line \($0)" }
        let report = PlayerReport(playerID: PeerID(), playerName: "Aki", game: "Obby", reason: .askedPersonal,
                                  note: "asked my school", chat: lines)
        XCTAssertEqual(report.chat.count, PlayerReport.keptChatLines)
        XCTAssertEqual(report.chat.last, "Aki: line 50")
        XCTAssertTrue(report.summary.contains("asked my school"))
        XCTAssertTrue(report.summary.contains("Aki: line 50"))
    }

    func testWhispersNeedFullChat() {
        XCTAssertTrue(Whisper.isAllowed(.full))
        XCTAssertFalse(Whisper.isAllowed(.phrases))
        XCTAssertFalse(Whisper.isAllowed(.off))
    }
}
