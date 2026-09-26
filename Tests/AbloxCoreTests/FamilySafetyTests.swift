import XCTest
@testable import AbloxCore

final class FamilySafetyTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testQuietHoursWrapPastMidnight() {
        let bedtime = QuietHours(start: 21 * 60, end: 7 * 60)
        XCTAssertTrue(bedtime.contains(minuteOfDay: 22 * 60))
        XCTAssertTrue(bedtime.contains(minuteOfDay: 3 * 60))
        XCTAssertFalse(bedtime.contains(minuteOfDay: 7 * 60))
        XCTAssertFalse(bedtime.contains(minuteOfDay: 12 * 60))
        let school = QuietHours(start: 9 * 60, end: 15 * 60)
        XCTAssertTrue(school.contains(minuteOfDay: 10 * 60))
        XCTAssertFalse(school.contains(minuteOfDay: 20 * 60))
        XCTAssertFalse(QuietHours(start: 60, end: 60).contains(minuteOfDay: 60), "an empty range is nothing, not everything")
        XCTAssertEqual(QuietHours.clock(7 * 60 + 5), "07:05")
    }

    func testPasscodeIsCheckedAndNotStoredPlain() throws {
        var controls = ParentalControls()
        XCTAssertFalse(controls.isLocked)
        XCTAssertTrue(controls.accepts("anything"), "no lock, nothing to get past")
        XCTAssertFalse(controls.setPasscode("12a4"))
        XCTAssertFalse(controls.setPasscode("123"))
        XCTAssertTrue(controls.setPasscode("2468"))
        XCTAssertTrue(controls.isLocked)
        XCTAssertTrue(controls.accepts("2468"))
        XCTAssertFalse(controls.accepts("2469"))

        let saved = String(decoding: try JSONEncoder().encode(controls), as: UTF8.self)
        XCTAssertFalse(saved.contains("2468"))
        let read = try JSONDecoder().decode(ParentalControls.self, from: Data(saved.utf8))
        XCTAssertTrue(read.accepts("2468"))

        controls.setPasscode(nil)
        XCTAssertFalse(controls.isLocked)
    }

    func testTheDailyLimitAndQuietHoursGatePlay() {
        var controls = ParentalControls()
        var log = PlaytimeLog()
        XCTAssertEqual(PlayGate.verdict(controls, log: log, now: date(26, 16), calendar: calendar), .allowed)
        XCTAssertNil(PlayGate.minutesLeft(controls, log: log, now: date(26, 16), calendar: calendar))

        controls.dailyLimitMinutes = 60
        log.add(seconds: 45 * 60, game: "Pom Town", at: date(26, 15), calendar: calendar)
        XCTAssertEqual(PlayGate.minutesLeft(controls, log: log, now: date(26, 16), calendar: calendar), 15)
        log.add(seconds: 20 * 60, game: "Pom Town", at: date(26, 16), calendar: calendar)
        XCTAssertEqual(PlayGate.verdict(controls, log: log, now: date(26, 16, 30), calendar: calendar), .dailyLimitReached(minutes: 60))
        // A new day, a new hour.
        XCTAssertEqual(PlayGate.verdict(controls, log: log, now: date(27, 16), calendar: calendar), .allowed)

        controls.quietHours = QuietHours(start: 21 * 60, end: 7 * 60)
        XCTAssertEqual(PlayGate.verdict(controls, log: log, now: date(27, 22), calendar: calendar), .quietHours(until: "07:00"))
        XCTAssertNotNil(PlayGate.message(for: .quietHours(until: "07:00")))
    }

    func testBreakReminders() {
        var controls = ParentalControls()
        XCTAssertFalse(PlayGate.breakDue(controls, sessionSeconds: 9999, lastReminder: 0))
        controls.breakEveryMinutes = 30
        XCTAssertFalse(PlayGate.breakDue(controls, sessionSeconds: 29 * 60, lastReminder: 0))
        XCTAssertTrue(PlayGate.breakDue(controls, sessionSeconds: 30 * 60, lastReminder: 0))
        XCTAssertFalse(PlayGate.breakDue(controls, sessionSeconds: 31 * 60, lastReminder: 30 * 60))
    }

    func testThePlaytimeLogKeepsDaysAndGames() {
        var log = PlaytimeLog()
        log.startedPlaying("Pom Town")
        log.startedPlaying("Pom Town")
        log.add(seconds: 600, game: "Pom Town", at: date(25, 10), calendar: calendar)
        log.add(seconds: 300, game: "Tower of Chaos", at: date(26, 10), calendar: calendar)
        log.add(seconds: 99_999, game: "Tower of Chaos", at: date(26, 11), calendar: calendar)
        XCTAssertEqual(log.seconds(on: date(26, 12), calendar: calendar), 300 + 3600, "a sleeping iPad does not count")
        XCTAssertEqual(log.favourites.first?.game, "Tower of Chaos")
        XCTAssertEqual(log.timesPlayed["Pom Town"], 2)
        let recent = log.recent(3, until: date(26, 12), calendar: calendar)
        XCTAssertEqual(recent.map(\.date), ["2026-09-26", "2026-09-25", "2026-09-24"])
        XCTAssertEqual(recent[2].seconds, 0)

        for day in 1...90 {
            log.add(seconds: 60, game: "x", at: date(1, 12).addingTimeInterval(Double(day) * 86400), calendar: calendar)
        }
        XCTAssertEqual(log.days.count, PlaytimeLog.keptDays)
    }

    func testTheCoinLedgerAndTheDailySpendingLimit() {
        var ledger = CoinLedger()
        ledger.record(100, reason: "Round", at: date(26, 10))
        ledger.record(-40, reason: "Cap", at: date(26, 11))
        ledger.record(-30, reason: "Crown", at: date(25, 11))
        XCTAssertEqual(ledger.entries.first?.reason, "Crown", "newest recorded first")
        XCTAssertEqual(ledger.spent(on: date(26, 12), calendar: calendar), 40)
        XCTAssertTrue(ledger.allows(spending: 60, limit: 100, on: date(26, 12), calendar: calendar))
        XCTAssertFalse(ledger.allows(spending: 61, limit: 100, on: date(26, 12), calendar: calendar))
        XCTAssertTrue(ledger.allows(spending: 9999, limit: nil, on: date(26, 12), calendar: calendar))
        for i in 0..<400 { ledger.record(1, reason: "\(i)") }
        XCTAssertEqual(ledger.entries.count, CoinLedger.keptEntries)
    }

    func testRudeNamesBecomePlayerAndJapaneseIsFiltered() {
        let moderator = ChatModerator(isFilterEnabled: false)
        XCTAssertEqual(moderator.cleanName("Stupid Sam"), "Player", "names are checked even with chat filtering off")
        XCTAssertEqual(moderator.cleanName("Aoi"), "Aoi")
        XCTAssertTrue(ChatModerator().filter("おまえ死ねよ").wasFiltered)
        XCTAssertFalse(ChatModerator().filter("それだけばかりだ").wasFiltered, "ばかり is an ordinary word")
        var profile = AvatarProfile.default
        profile.displayName = "キモい人"
        XCTAssertEqual(profile.sanitizedForNetwork().displayName, "Player")
    }

    func testQuickChatPhrasesAreTranslated() {
        for phrase in QuickChat.phrases {
            XCTAssertNotNil(Strings.japanese[phrase], phrase)
        }
    }
}

final class PlayPreferencesTests: XCTestCase {

    func testOldSettingsReadWithNewFieldsAtTheirDefaults() throws {
        let old = #"{"cameraShake":false,"hapticStrength":"strong"}"#
        let read = try JSONDecoder().decode(PlayPreferences.self, from: Data(old.utf8))
        XCTAssertFalse(read.cameraShake)
        XCTAssertEqual(read.hapticStrength, .strong)
        XCTAssertEqual(read.textSize, .standard)
        XCTAssertTrue(read.coolDownWhenHot)
        // An unknown value falls back rather than losing everything.
        let odd = #"{"hapticStrength":"earthquake","cameraZoom":99,"dimming":-3}"#
        let fixed = try JSONDecoder().decode(PlayPreferences.self, from: Data(odd.utf8))
        XCTAssertEqual(fixed.hapticStrength, .medium)
        XCTAssertEqual(fixed.cameraZoom, 2)
        XCTAssertEqual(fixed.dimming, 0)
        let again = try JSONDecoder().decode(PlayPreferences.self, from: JSONEncoder().encode(fixed))
        XCTAssertEqual(again, fixed)
    }

    func testBatteryAndHeatCapTheGraphics() {
        var preferences = PlayPreferences()
        XCTAssertNil(preferences.graphicsCap(lowPowerMode: false, heat: .fair))
        XCTAssertEqual(preferences.graphicsCap(lowPowerMode: true, heat: .nominal), .medium)
        XCTAssertEqual(preferences.graphicsCap(lowPowerMode: false, heat: .serious), .medium)
        XCTAssertEqual(preferences.graphicsCap(lowPowerMode: true, heat: .critical), .low)
        preferences.coolDownWhenHot = false
        XCTAssertNil(preferences.graphicsCap(lowPowerMode: false, heat: .critical))
        preferences.batterySaver = true
        XCTAssertEqual(preferences.graphicsCap(lowPowerMode: false, heat: .critical), .medium)
    }

    func testComfortSettings() {
        var preferences = PlayPreferences()
        XCTAssertEqual(preferences.shake(strength: 1), 1)
        preferences.reduceFlashing = true
        XCTAssertEqual(preferences.shake(strength: 1), 0.4, accuracy: 0.0001)
        preferences.cameraShake = false
        XCTAssertEqual(preferences.shake(strength: 1), 0)
        preferences.fieldOfViewBoost = 15
        XCTAssertEqual(preferences.fieldOfView(game: 65), 80)
        XCTAssertEqual(preferences.fieldOfView(game: 145), 150)
    }
}
