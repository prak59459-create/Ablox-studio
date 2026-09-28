import XCTest
@testable import AbloxCore

/// Settings, family and access, the second round.
final class FamilyExtrasTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testWeekendLimitExtraTimeAndDaysOff() {
        var controls = ParentalControls()
        controls.dailyLimitMinutes = 60
        controls.family.weekendLimitMinutes = 120
        let monday = date(2026, 9, 28), saturday = date(2026, 9, 26)
        XCTAssertEqual(controls.limit(on: monday, calendar: calendar), 60)
        XCTAssertEqual(controls.limit(on: saturday, calendar: calendar), 120)
        controls.family.giveExtra(15, on: PlaytimeLog.dayKey(monday, calendar: calendar))
        controls.family.giveExtra(15, on: PlaytimeLog.dayKey(monday, calendar: calendar))
        XCTAssertEqual(controls.limit(on: monday, calendar: calendar), 90, "extra time adds up today")
        XCTAssertEqual(controls.limit(on: date(2026, 9, 29), calendar: calendar), 60, "and is gone tomorrow")

        var log = PlaytimeLog()
        // (One report is capped at an hour, so two of 35 minutes.)
        log.add(seconds: 35 * 60, game: "Kart", at: monday, calendar: calendar)
        log.add(seconds: 35 * 60, game: "Kart", at: monday, calendar: calendar)
        XCTAssertEqual(PlayGate.verdict(controls, log: log, now: monday, calendar: calendar), .allowed)
        XCTAssertEqual(PlayGate.minutesLeft(controls, log: log, now: monday, calendar: calendar), 20)

        controls.family.daysOff = [2] // Monday
        XCTAssertEqual(PlayGate.verdict(controls, log: PlaytimeLog(), now: monday, calendar: calendar), .dayOff)
        XCTAssertNotNil(PlayGate.message(for: .dayOff))
        XCTAssertFalse(FamilyExtras.weekdayName(2, calendar: calendar).isEmpty)
    }

    func testChosenGamesPurchasesAndOldSettings() throws {
        var family = FamilyExtras()
        XCTAssertTrue(family.allows(game: "kart"))
        family.hiddenGames = ["kart"]
        XCTAssertFalse(family.allows(game: "kart"))
        family.onlyChosenGames = true
        family.chosenGames = ["cafe"]
        XCTAssertTrue(family.allows(game: "cafe"))
        XCTAssertFalse(family.allows(game: "boat"))
        family.askAbove = 300
        XCTAssertFalse(family.needsPermission(price: 300))
        XCTAssertTrue(family.needsPermission(price: 301))

        // Controls saved before any of this still load, with it all off.
        var controls = ParentalControls()
        controls.dailyLimitMinutes = 45
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(controls)) as? [String: Any])
        json["extras"] = nil
        let old = try JSONDecoder().decode(ParentalControls.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.dailyLimitMinutes, 45)
        XCTAssertEqual(old.family, FamilyExtras())
        controls.family = family
        XCTAssertEqual(try JSONDecoder().decode(ParentalControls.self, from: JSONEncoder().encode(controls)).family, family)
        let odd = try JSONDecoder().decode(FamilyExtras.self, from: Data(#"{"daysOff":[0,3,9],"extraMinutes":-5}"#.utf8))
        XCTAssertEqual(odd.daysOff, [3])
        XCTAssertEqual(odd.extraMinutes, 0)
    }

    func testPresetsAndTheLog() {
        var controls = ParentalControls()
        let before = controls
        AgePreset.young.apply(to: &controls)
        XCTAssertEqual(controls.chat, .phrases)
        XCTAssertEqual(controls.dailyLimitMinutes, 60)
        XCTAssertFalse(controls.allowPublicRooms)
        let changes = controls.changes(from: before)
        XCTAssertTrue(changes.contains(L("Daily limit: {}", L("{} minutes", 60))))
        XCTAssertTrue(changes.contains(L("Public rooms not allowed")))
        XCTAssertEqual(controls.changes(from: controls), [])
        AgePreset.teen.apply(to: &controls)
        XCTAssertNil(controls.dailyLimitMinutes)
        XCTAssertEqual(controls.chat, .full)
        for preset in AgePreset.allCases { XCTAssertFalse(preset.summary.isEmpty) }

        var log = FamilyLog()
        log.record(["a", "b"], at: Date(timeIntervalSince1970: 1))
        log.record(["c"], at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(log.entries.map(\.text), ["c", "a", "b"])
        for n in 0..<200 { log.record(["x\(n)"]) }
        XCTAssertEqual(log.entries.count, FamilyLog.kept)
    }

    func testAccessOptionsAndCaptions() throws {
        var preferences = PlayPreferences()
        preferences.access.boldText = true
        preferences.access.movementSpeed = 0.7
        XCTAssertEqual(try JSONDecoder().decode(PlayPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        let odd = try JSONDecoder().decode(PlayPreferences.self, from: Data(#"{"access":{"movementSpeed":5,"soundCaptions":true}}"#.utf8))
        XCTAssertEqual(odd.access.movementSpeed, 1)
        XCTAssertTrue(odd.access.soundCaptions)
        for cue in SoundCue.allCases { XCTAssertFalse(cue.caption.isEmpty, "\(cue)") }
        XCTAssertTrue(SoundCue.alarm.isImportant)
        XCTAssertFalse(SoundCue.click.isImportant)
    }

    func testWhatsAroundMe() {
        let origin = Vec3(0, 0, 0)
        // Facing −z (yaw 0).
        XCTAssertEqual(SurroundingsReport.direction(from: origin, yaw: 0, to: Vec3(0, 0, -5)), L("ahead"))
        XCTAssertEqual(SurroundingsReport.direction(from: origin, yaw: 0, to: Vec3(5, 0, 0)), L("to the right"))
        XCTAssertEqual(SurroundingsReport.direction(from: origin, yaw: 0, to: Vec3(-5, 0, 0)), L("to the left"))
        XCTAssertEqual(SurroundingsReport.direction(from: origin, yaw: 0, to: Vec3(0, 0, 5)), L("behind"))
        // Facing +x (yaw 90): what was on the right is ahead.
        XCTAssertEqual(SurroundingsReport.direction(from: origin, yaw: 90, to: Vec3(5, 0, 0)), L("ahead"))
        XCTAssertEqual(SurroundingsReport.direction(from: origin, yaw: 0, to: origin), L("right here"))

        let me = PlayerSnapshot(peerID: PeerID(), profile: AvatarProfile(displayName: "Me"), position: origin)
        XCTAssertEqual(SurroundingsReport.describe(me: me, others: [me]), L("Nobody else is nearby."))
        let kai = PlayerSnapshot(peerID: PeerID(), profile: AvatarProfile(displayName: "Kai"), position: Vec3(0, 0, -4))
        let report = SurroundingsReport.describe(me: me, others: [me, kai])
        XCTAssertTrue(report.contains("Kai"))
        XCTAssertTrue(report.contains(L("ahead")))
    }

    func testPauseQuietWarningsAndSchoolDays() {
        var controls = ParentalControls()
        controls.family.pausedNow = true
        XCTAssertEqual(PlayGate.verdict(controls, log: PlaytimeLog(), now: date(2026, 9, 28), calendar: calendar), .paused)
        XCTAssertNotNil(PlayGate.message(for: .paused))
        controls.family.pausedNow = false
        controls.quietHours = QuietHours(start: 21 * 60, end: 7 * 60)
        XCTAssertEqual(PlayGate.minutesUntilQuiet(controls, now: date(2026, 9, 28, 20), calendar: calendar), 60)
        XCTAssertEqual(PlayGate.minutesUntilQuiet(controls, now: date(2026, 9, 28, 22), calendar: calendar), 0)
        XCTAssertEqual(PlayGate.verdict(controls, log: PlaytimeLog(), now: date(2026, 9, 26, 22), calendar: calendar),
                       .quietHours(until: "07:00"))
        controls.family.quietSchoolDaysOnly = true
        XCTAssertEqual(PlayGate.verdict(controls, log: PlaytimeLog(), now: date(2026, 9, 26, 22), calendar: calendar), .allowed,
                       "a Saturday night")
        XCTAssertNil(PlayGate.minutesUntilQuiet(controls, now: date(2026, 9, 26, 20), calendar: calendar))
        XCTAssertEqual(PlayGate.verdict(controls, log: PlaytimeLog(), now: date(2026, 9, 28, 22), calendar: calendar),
                       .quietHours(until: "07:00"), "a Monday night")
        let before = ParentalControls()
        var after = before
        after.family.shopAllowed = false
        after.family.chatFriendsOnly = true
        XCTAssertEqual(after.changes(from: before), [L("Shop put away"), L("Chat with friends only")])
    }

    func testTipsAndSettingsFiles() throws {
        XCTAssertEqual(SettingsTips.tip(on: "2026-09-28"), SettingsTips.tip(on: "2026-09-28"))
        XCTAssertGreaterThanOrEqual(Set(SettingsTips.all).count, 10)
        var preferences = PlayPreferences()
        preferences.hud.showCompass = true
        preferences.chat.readAloud = true
        let data = try SettingsTransfer(preferences: preferences).data()
        XCTAssertEqual(SettingsTransfer.read(data)?.preferences, preferences)
        XCTAssertNil(SettingsTransfer.read(Data("{}".utf8)))
        XCTAssertNil(SettingsTransfer.read(Data(#"{"version":99,"app":"Ablox","preferences":{}}"#.utf8)))
        XCTAssertNil(SettingsTransfer.read(Data(#"{"version":1,"app":"Other","preferences":{}}"#.utf8)))
    }
}
