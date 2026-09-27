import XCTest
@testable import AbloxCore

final class MissionsAndHabitsTests: XCTestCase {

    // MARK: Missions

    func testTheSameDayHasTheSameThreeMissions() {
        let a = MissionBook.missions(for: "2026-09-28")
        let b = MissionBook.missions(for: "2026-09-28")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, MissionBook.missionsPerDay)
        XCTAssertEqual(a.first?.kind, .playMinutes)
        XCTAssertEqual(Set(a.map(\.kind)).count, a.count, "no kind twice")
        XCTAssertTrue(a.allSatisfy { $0.target > 0 && $0.reward > 0 })
    }

    func testDaysDiffer() {
        let days = (1...28).map { String(format: "2026-10-%02d", $0) }
        let sets = Set(days.map { MissionBook.missions(for: $0).map(\.id).joined(separator: ",") })
        XCTAssertGreaterThan(sets.count, 3, "a month should not repeat one set")
    }

    func testProgressClaimAndNewDay() {
        let day = "2026-09-28"
        var book = MissionBook()
        let minutes = MissionBook.missions(for: day)[0]
        XCTAssertNil(book.claim(minutes, on: day), "not done yet")
        book.record(.playMinutes, amount: minutes.target * 60 - 1, on: day)
        XCTAssertFalse(book.isDone(minutes, on: day))
        book.record(.playMinutes, amount: 1, on: day)
        XCTAssertTrue(book.isDone(minutes, on: day))
        XCTAssertEqual(book.waitingRewards(on: day), 1)
        XCTAssertEqual(book.claim(minutes, on: day), minutes.reward)
        XCTAssertNil(book.claim(minutes, on: day), "only once")
        XCTAssertEqual(book.waitingRewards(on: day), 0)

        // Tomorrow starts afresh.
        XCTAssertEqual(book.progress(of: minutes, on: "2026-09-29"), 0)
        book.record(.useEmote, on: "2026-09-29")
        XCTAssertFalse(book.isClaimed(minutes, on: "2026-09-29"))
    }

    func testDifferentGamesCountEachGameOnce() {
        let day = "2026-09-28"
        var book = MissionBook()
        let mission = Mission(kind: .differentGames, target: 2, reward: 26)
        book.played(game: "Obby", on: day)
        book.played(game: "Obby", on: day)
        XCTAssertEqual(book.progress(of: mission, on: day), 1)
        book.played(game: "Tycoon", on: day)
        XCTAssertTrue(book.isDone(mission, on: day))
    }

    func testMissionsSurviveBeingSaved() throws {
        var book = MissionBook()
        book.record(.takePicture, on: "2026-09-28")
        book.played(game: "Obby", on: "2026-09-28")
        let data = try JSONEncoder().encode(book)
        XCTAssertEqual(try JSONDecoder().decode(MissionBook.self, from: data), book)
    }

    // MARK: After a game

    func testSummaryCountsWhatChanged() {
        let start = Date(timeIntervalSince1970: 1_000)
        let before = SessionSummary.Snapshot(at: start, lifetimeCoins: 100, missionsDone: ["playMinutes"], badges: ["firstGame"])
        let after = SessionSummary.Snapshot(at: start.addingTimeInterval(125), lifetimeCoins: 140,
                                            missionsDone: ["playMinutes", "finishRound"], badges: ["firstGame", "explorer"])
        let summary = SessionSummary(game: "Obby", before: before, after: after)
        XCTAssertEqual(summary.coins, 40)
        XCTAssertEqual(summary.missionsDone, 1)
        XCTAssertEqual(summary.badges, ["explorer"])
        XCTAssertTrue(summary.isWorthShowing)
        XCTAssertEqual(summary.seconds, 125)
    }

    func testAQuickPeekIsNotWorthACard() {
        let start = Date()
        let snapshot = SessionSummary.Snapshot(at: start, lifetimeCoins: 5, missionsDone: [], badges: [])
        var later = snapshot
        later.at = start.addingTimeInterval(10)
        XCTAssertFalse(SessionSummary(game: "x", before: snapshot, after: later).isWorthShowing)
    }

    // MARK: Saving up

    func testSavingsGoal() {
        XCTAssertEqual(SavingsGoal.progress(balance: 50, price: 200), 0.25)
        XCTAssertEqual(SavingsGoal.progress(balance: 500, price: 200), 1)
        XCTAssertEqual(SavingsGoal.remaining(balance: 50, price: 200), 150)
        XCTAssertEqual(SavingsGoal.remaining(balance: 250, price: 200), 0)
        XCTAssertEqual(SavingsGoal.roundsToGo(balance: 50, price: 200, averagePerRound: 20), 8)
        XCTAssertNil(SavingsGoal.roundsToGo(balance: 50, price: 200, averagePerRound: 0))
        XCTAssertEqual(SavingsGoal.roundsToGo(balance: 300, price: 200, averagePerRound: 0), 0)
    }

    // MARK: A timer of one's own

    func testSelfTimerWarnsThenFinishes() {
        let start = Date(timeIntervalSince1970: 0)
        var timer = SelfTimer()
        XCTAssertEqual(timer.tick(now: start), .none)
        timer.start(minutes: 5, now: start)
        XCTAssertEqual(timer.remaining(now: start), 300)
        XCTAssertEqual(timer.tick(now: start.addingTimeInterval(100)), .none)
        XCTAssertEqual(timer.tick(now: start.addingTimeInterval(241)), .warning)
        XCTAssertEqual(timer.tick(now: start.addingTimeInterval(250)), .none, "warned once")
        XCTAssertEqual(timer.tick(now: start.addingTimeInterval(300)), .finished)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(SelfTimer.clock(245), "4:05")
    }

    func testCancelledTimerSaysNothing() {
        let start = Date()
        var timer = SelfTimer()
        timer.start(minutes: 10, now: start)
        timer.cancel()
        XCTAssertEqual(timer.tick(now: start.addingTimeInterval(1_000)), .none)
        XCTAssertNil(timer.remaining(now: start))
    }

    // MARK: A month of play

    func testCalendarLaysOutTheMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1 // Sunday
        let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        var log = PlaytimeLog()
        log.add(seconds: 1_800, game: "Obby", at: calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!, calendar: calendar)
        log.add(seconds: 4_000, game: "Obby", at: calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!, calendar: calendar)
        let cells = PlayCalendar.cells(month: september, log: log, today: september, calendar: calendar)
        // 1 September 2026 is a Tuesday: two blanks, then 30 days.
        XCTAssertEqual(cells.filter { $0.day == nil }.count, 2)
        XCTAssertEqual(cells.compactMap(\.day), Array(1...30))
        XCTAssertEqual(cells.first { $0.day == 3 }?.minutes, 30)
        XCTAssertEqual(cells.first { $0.day == 15 }?.isToday, true)
        let totals = PlayCalendar.totals(cells)
        XCTAssertEqual(totals.days, 2)
        XCTAssertEqual(totals.minutes, 30 + 60, "an hour at most per report")
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count, "ids unique")
    }

    func testCalendarLevels() {
        XCTAssertEqual(PlayCalendar.level(minutes: 0), 0)
        XCTAssertEqual(PlayCalendar.level(minutes: 5), 1)
        XCTAssertEqual(PlayCalendar.level(minutes: 30), 2)
        XCTAssertEqual(PlayCalendar.level(minutes: 90), 3)
    }

    func testCalendarTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let saved = Localization.language
        defer { Localization.language = saved }
        Localization.language = .japanese
        XCTAssertEqual(PlayCalendar.title(month: date, calendar: calendar), "2026年9月")
        Localization.language = .english
        XCTAssertEqual(PlayCalendar.title(month: date, calendar: calendar), "September 2026")
    }

    // MARK: The crosshair

    func testCrosshairPreferencesDefaultAndSurviveSaving() throws {
        var preferences = PlayPreferences()
        XCTAssertEqual(preferences.crosshair, .plus)
        preferences.crosshair = .dot
        preferences.crosshairColor = .green
        let data = try JSONEncoder().encode(preferences)
        let back = try JSONDecoder().decode(PlayPreferences.self, from: data)
        XCTAssertEqual(back.crosshair, .dot)
        XCTAssertEqual(back.crosshairColor, .green)
        // Saved before the crosshair could be chosen.
        let old = try JSONDecoder().decode(PlayPreferences.self, from: Data("{\"showMap\":false}".utf8))
        XCTAssertEqual(old.crosshair, .plus)
        XCTAssertFalse(old.showMap)
        XCTAssertNil(CrosshairStyle.off.symbolName)
    }

    // MARK: Friends nearby

    func testAFriendInARoomIsAnnouncedOnce() {
        let friend = PeerID(), stranger = PeerID()
        var sightings = FriendSightings()
        let room = (id: "room-a", tag: RoomTag(players: [stranger, friend]))
        let first = sightings.newlySeen(rooms: [room], friends: [friend])
        XCTAssertEqual(first, [FriendSightings.Sighting(roomID: "room-a", friend: friend)])
        XCTAssertTrue(sightings.newlySeen(rooms: [room], friends: [friend]).isEmpty, "said once")
        // The room goes and comes back: said again.
        XCTAssertTrue(sightings.newlySeen(rooms: [], friends: [friend]).isEmpty)
        XCTAssertEqual(sightings.newlySeen(rooms: [room], friends: [friend]).count, 1)
        XCTAssertTrue(sightings.newlySeen(rooms: [(id: "room-b", tag: RoomTag(players: [stranger]))], friends: [friend]).isEmpty)
    }

    // MARK: Nicknames

    func testFriendNickname() throws {
        let id = PeerID()
        var book = SocialBook()
        book.addFriend(id, name: "Taro")
        book.setNickname("  Taro from school  ", for: id)
        XCTAssertEqual(book.friends.first?.shownName, "Taro from school")
        XCTAssertEqual(book.friends.first?.name, "Taro")
        let data = try JSONEncoder().encode(book)
        XCTAssertEqual(try JSONDecoder().decode(SocialBook.self, from: data).friends.first?.nickname, "Taro from school")
        book.setNickname("", for: id)
        XCTAssertEqual(book.friends.first?.shownName, "Taro")
        book.setNickname(String(repeating: "あ", count: 60), for: id)
        XCTAssertEqual(book.friends.first?.nickname?.count, SocialBook.maximumNicknameLength)
    }

    // MARK: Names for new worlds

    func testWorldNameIdeas() {
        let a = WorldNameIdeas.suggest(seed: 42, language: .english)
        XCTAssertEqual(a, WorldNameIdeas.suggest(seed: 42, language: .english))
        XCTAssertTrue(a.contains(" "))
        let taken: Set<String> = [a]
        XCTAssertNotEqual(WorldNameIdeas.suggest(seed: 42, language: .english, taken: taken), a)
        let japanese = WorldNameIdeas.suggest(seed: 7, language: .japanese)
        XCTAssertFalse(japanese.contains(" "))
        XCTAssertFalse(japanese.isEmpty)
        // Every pair taken: numbered instead.
        var everything = Set<String>()
        for first in WorldNameIdeas.english.first {
            for second in WorldNameIdeas.english.second { everything.insert(first + " " + second) }
        }
        let numbered = WorldNameIdeas.suggest(seed: 1, language: .english, taken: everything)
        XCTAssertFalse(everything.contains(numbered))
        XCTAssertTrue(numbered.hasSuffix(" 2"))
    }
}
