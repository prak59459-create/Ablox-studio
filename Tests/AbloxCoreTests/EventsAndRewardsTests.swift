import XCTest
@testable import AbloxCore

/// Missions, events and coins, the second round.
final class EventsAndRewardsTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testWeeklyMissions() {
        let week = WeeklyMissionBook.weekKey(date(2026, 9, 28))
        XCTAssertEqual(week, "2026-W40")
        let missions = WeeklyMissionBook.missions(for: week)
        XCTAssertEqual(missions.count, 3)
        XCTAssertEqual(missions.first?.kind, .playMinutes)
        XCTAssertEqual(Set(missions.map(\.id)).count, 3)
        XCTAssertEqual(WeeklyMissionBook.missions(for: week), missions, "the same all week")
        var book = WeeklyMissionBook()
        let minutes = missions[0]
        book.record(.playMinutes, amount: minutes.target * 60 - 60, on: week)
        XCTAssertFalse(book.isDone(minutes, on: week))
        XCTAssertNil(book.claim(minutes, on: week))
        book.record(.playMinutes, amount: 60, on: week)
        XCTAssertEqual(book.claim(minutes, on: week), minutes.reward)
        XCTAssertNil(book.claim(minutes, on: week), "once")
        book.roll(to: "2026-W41")
        XCTAssertEqual(book.progress(of: minutes, on: "2026-W41"), 0)
    }

    func testDailySwapsAndTheAllDoneBonus() {
        var book = MissionBook()
        let day = "2026-09-28"
        let missions = book.missions(on: day)
        let other = missions[1]
        XCTAssertFalse(book.canSwap(missions[0], on: day), "play time stays")
        let swapped = book.swap(other, on: day)
        XCTAssertNotNil(swapped)
        XCTAssertNotEqual(swapped?.kind, other.kind)
        XCTAssertFalse(missions.map(\.kind).contains(swapped!.kind), "not one already there")
        XCTAssertEqual(book.missions(on: day)[1], swapped)
        XCTAssertNil(book.swap(book.missions(on: day)[2], on: day), "one swap a day")
        // Tomorrow is a fresh start.
        XCTAssertTrue(book.canSwap(MissionBook.missions(for: "2026-09-29")[1], on: "2026-09-29"))

        XCTAssertNil(book.claimAllDoneBonus(on: day))
        for mission in book.missions(on: day) {
            switch mission.kind {
            case .differentGames: for n in 0..<mission.target { book.played(game: "g\(n)", on: day) }
            case .playMinutes: book.record(.playMinutes, amount: mission.target * 60, on: day)
            default: book.record(mission.kind, amount: mission.target, on: day)
            }
        }
        XCTAssertTrue(book.isAllDoneBonusWaiting(on: day))
        XCTAssertEqual(book.claimAllDoneBonus(on: day), MissionBook.allDoneBonus)
        XCTAssertNil(book.claimAllDoneBonus(on: day))
        XCTAssertFalse(book.isAllDoneBonusWaiting(on: day))
    }

    func testStreakFreezesAndMilestones() {
        var bonus = DailyBonus()
        for day in 1...7 { _ = bonus.claim(on: date(2026, 9, day), calendar: calendar) }
        XCTAssertEqual(bonus.streak, 7)
        XCTAssertEqual(bonus.freezes, 1)
        // The 8th is missed; the freeze covers it.
        _ = bonus.claim(on: date(2026, 9, 9), calendar: calendar)
        XCTAssertEqual(bonus.streak, 8)
        XCTAssertEqual(bonus.freezes, 0)
        // Two days missed, with no freeze: start again.
        _ = bonus.claim(on: date(2026, 9, 12), calendar: calendar)
        XCTAssertEqual(bonus.streak, 1)
        XCTAssertEqual(StreakRewards.bonus(forStreak: 7), 60)
        XCTAssertNil(StreakRewards.bonus(forStreak: 8))
        XCTAssertEqual(StreakRewards.next(after: 8)?.days, 14)
        XCTAssertEqual(StreakRewards.weekendMultiplier(on: date(2026, 9, 26), calendar: calendar), 2, "a Saturday")
        XCTAssertEqual(StreakRewards.weekendMultiplier(on: date(2026, 9, 28), calendar: calendar), 1)
    }

    func testSeasonalEvents() {
        XCTAssertEqual(SeasonalEvent.current(on: date(2026, 10, 31), calendar: calendar), .halloween)
        XCTAssertEqual(SeasonalEvent.current(on: date(2026, 1, 3), calendar: calendar), .newYear)
        XCTAssertNil(SeasonalEvent.current(on: date(2026, 9, 28), calendar: calendar))
        XCTAssertEqual(SeasonalEvent.halloween.daysLeft(on: date(2026, 10, 29), calendar: calendar), 2)
        let next = SeasonalEvent.next(after: date(2026, 9, 28), calendar: calendar)
        XCTAssertEqual(next?.event, .halloween)
        XCTAssertEqual(next?.days, 22)
        XCTAssertEqual(SeasonalEvent.next(after: date(2026, 12, 31), calendar: calendar)?.event, .newYear)
        XCTAssertEqual(SeasonalEvent.halloween.boosted(100), 115)
        XCTAssertEqual(SeasonalEvent.christmas.boosted(10), 13)
        // Events never overlap, and everything they put on sale exists.
        for day in 0..<366 {
            let when = calendar.date(byAdding: .day, value: day, to: date(2027, 1, 1))!
            XCTAssertLessThanOrEqual(SeasonalEvent.allCases.filter { $0.isOn(when, calendar: calendar) }.count, 1)
        }
        for event in SeasonalEvent.allCases {
            for id in event.saleItemIDs { XCTAssertNotNil(ShopCatalogue.item(id: id), "\(event): \(id)") }
            XCTAssertFalse(event.displayName.isEmpty)
        }
    }

    func testDealsSalesAndRefunds() {
        let day = "2026-09-28"
        let deal = ShopDeals.dailyDeal(on: day, owned: [])
        XCTAssertNotNil(deal)
        XCTAssertEqual(ShopDeals.dailyDeal(on: day, owned: []), deal, "the same all day")
        let item = deal!
        XCTAssertEqual(ShopDeals.price(of: item, day: day, event: nil, owned: []), item.price - item.price * 30 / 100)
        let witch = ShopCatalogue.item(id: "hat.witch")!
        XCTAssertEqual(ShopDeals.price(of: witch, day: "x", event: .halloween, owned: []), witch.price - witch.price * 25 / 100)
        XCTAssertEqual(ShopDeals.price(of: witch, day: "x", event: .christmas, owned: []) == witch.price,
                       ShopDeals.dailyDeal(on: "x", owned: [])?.id != witch.id)

        var wallet = PlayerWallet(coins: 1_000)
        XCTAssertTrue(wallet.purchase(witch.id, price: 10).succeeded)
        XCTAssertEqual(wallet.coins, 990)
        XCTAssertTrue(wallet.refund(witch.id, coins: 10))
        XCTAssertFalse(wallet.owns(witch.id))
        XCTAssertEqual(wallet.coins, 1_000)
        XCTAssertFalse(wallet.refund(witch.id, coins: 10), "not owned any more")
        XCTAssertFalse(wallet.refund("hat.none", coins: 5), "free things are not refunded")
        XCTAssertEqual(wallet.purchase(witch.id, price: 99_999), .purchased(witch), "never more than its price")

        var look = AvatarProfile(displayName: "Kai", hat: .witch)
        look.trail = .fire
        look = look.removing(witch)
        XCTAssertEqual(look.hat, AvatarProfile.HatStyle.none)
        XCTAssertEqual(look.removing(ShopCatalogue.item(id: "trail.fire")!).trail, AvatarProfile.Trail.none)
    }

    func testTheCoinJarGrowsWeekly() {
        var jar = CoinJar()
        let start = Date(timeIntervalSince1970: 1_000_000)
        jar.put(200, now: start)
        XCTAssertEqual(jar.grow(now: start.addingTimeInterval(6 * 86_400)), 0)
        XCTAssertEqual(jar.grow(now: start.addingTimeInterval(7 * 86_400 + 60)), 10)
        XCTAssertEqual(jar.balance, 210)
        XCTAssertEqual(jar.take(50, now: start.addingTimeInterval(8 * 86_400)), 50)
        XCTAssertEqual(jar.take(9_999, now: start.addingTimeInterval(8 * 86_400)), 160)
        XCTAssertEqual(jar.balance, 0)
        var big = CoinJar()
        big.put(4_000, now: start)
        XCTAssertEqual(big.grow(now: start.addingTimeInterval(7 * 86_400)), CoinJar.weeklyMaximum, "capped at 50 a week")
        XCTAssertEqual(big.room(from: 5_000), CoinJar.capacity - big.balance)
    }

    /// The jar's slider only exists when its two ends differ: SwiftUI stops
    /// the app for `Slider(in: 10...10, step: 10)`, which is what 10 to 19
    /// coins and an empty jar used to make, on the Play tab, at launch.
    func testTheCoinJarSliderNeverHasTwoEqualEnds() {
        XCTAssertEqual(CoinJar.sliderTop(coins: 15, saved: 0), 10, "one step: no slider")
        XCTAssertEqual(CoinJar.sliderTop(coins: 0, saved: 0), 10)
        XCTAssertEqual(CoinJar.sliderTop(coins: 25, saved: 0), 20)
        XCTAssertEqual(CoinJar.sliderTop(coins: 0, saved: 45), 40, "taking out what is saved")
        XCTAssertEqual(CoinJar.sliderTop(coins: 99_999, saved: 4_990), 4_990, "the jar is nearly full")
        XCTAssertEqual(CoinJar.sliderTop(coins: -5, saved: -5), 10)
        for coins in stride(from: 0, through: 200, by: 1) {
            for saved in [0, 5, 10, 11, 60, 4_999, 5_000] {
                let top = CoinJar.sliderTop(coins: coins, saved: saved)
                XCTAssertGreaterThanOrEqual(top, CoinJar.step)
                XCTAssertEqual(top % CoinJar.step, 0)
            }
        }
        XCTAssertEqual(CoinJar.chosen(50, top: 30), 30, "the old default, above what there is")
        XCTAssertEqual(CoinJar.chosen(50, top: 10), 10)
        XCTAssertEqual(CoinJar.chosen(24, top: 100), 20)
        XCTAssertEqual(CoinJar.chosen(-3, top: 100), 10)
        XCTAssertEqual(CoinJar.chosen(.nan, top: 100), 10)
        XCTAssertEqual(CoinJar.chosen(.infinity, top: 100), 100)
    }

    func testFirstTimesBirthdayAndBadgeRewards() {
        var firsts = FirstTimes()
        XCTAssertEqual(firsts.firstVisit("Kart"), FirstTimes.newGameCoins)
        XCTAssertNil(firsts.firstVisit("Kart"))
        XCTAssertEqual(firsts.hosted(on: "d1"), FirstTimes.hostCoins)
        XCTAssertNil(firsts.hosted(on: "d1"))
        XCTAssertEqual(firsts.playedWithFriend(on: "d1"), FirstTimes.friendCoins)
        XCTAssertEqual(firsts.playedWithFriend(on: "d2"), FirstTimes.friendCoins)

        var birthday = Birthday(month: 9, day: 28)
        XCTAssertTrue(birthday.isToday(date(2026, 9, 28), calendar: calendar))
        XCTAssertNil(birthday.claimGift(on: date(2026, 9, 27), calendar: calendar))
        XCTAssertEqual(birthday.claimGift(on: date(2026, 9, 28), calendar: calendar), Birthday.giftCoins)
        XCTAssertNil(birthday.claimGift(on: date(2026, 9, 28), calendar: calendar), "once a year")
        XCTAssertEqual(birthday.claimGift(on: date(2027, 9, 28), calendar: calendar), Birthday.giftCoins)
        XCTAssertEqual(Birthday(month: 40, day: -3).month, 12)

        XCTAssertEqual(Achievement.firstGame.reward, 25)
        XCTAssertEqual(Achievement.levelTen.reward, 40)
    }

    func testTheWeekInNumbers() {
        var log = PlaytimeLog()
        let now = date(2026, 9, 28)
        log.add(seconds: 600, game: "Kart", at: now, calendar: calendar)
        log.add(seconds: 300, game: "Kart", at: calendar.date(byAdding: .day, value: -2, to: now)!, calendar: calendar)
        log.add(seconds: 1_200, game: "Cafe", at: calendar.date(byAdding: .day, value: -9, to: now)!, calendar: calendar)
        var ledger = CoinLedger()
        ledger.record(50, reason: "a", at: now)
        ledger.record(-20, reason: "b", at: now)
        ledger.record(99, reason: "old", at: calendar.date(byAdding: .day, value: -20, to: now)!)
        let summary = WeekSummary.make(days: log.days, ledger: ledger, now: now, calendar: calendar)
        XCTAssertEqual(summary.coinsEarned, 50)
        XCTAssertEqual(summary.coinsSpent, 20)
        XCTAssertEqual(summary.minutes, 15)
        XCTAssertEqual(summary.daysPlayed, 2)
        XCTAssertEqual(summary.lastWeekMinutes, 20)
    }

    func testWeeklyAllDoneHintsPreviewAndSavingDays() {
        let week = "2026-W40"
        var book = WeeklyMissionBook()
        XCTAssertNil(book.claimAllDoneBonus(on: week))
        for mission in book.missions(on: week) {
            switch mission.kind {
            case .differentGames: for n in 0..<mission.target { book.played(game: "g\(n)", on: week) }
            case .playMinutes: book.record(.playMinutes, amount: mission.target * 60, on: week)
            default: book.record(mission.kind, amount: mission.target, on: week)
            }
        }
        XCTAssertEqual(book.done(on: week).count, 3)
        XCTAssertEqual(book.claimAllDoneBonus(on: week), WeeklyMissionBook.allDoneBonus)
        XCTAssertNil(book.claimAllDoneBonus(on: week))
        XCTAssertEqual(WeeklyMissionBook.daysLeft(on: date(2026, 9, 28)), 6, "a Monday")
        XCTAssertEqual(WeeklyMissionBook.daysLeft(on: date(2026, 10, 4)), 0, "a Sunday")

        for kind in MissionKind.allCases { XCTAssertFalse(kind.hint.isEmpty) }

        // Friday with a 5-day streak: Saturday and Sunday doubled; day 7 a prize.
        let preview = StreakRewards.preview(streak: 5, from: date(2026, 9, 25), days: 3, calendar: calendar)
        XCTAssertEqual(preview.count, 3)
        XCTAssertEqual(preview[0].coins, (DailyBonus.base + DailyBonus.perDay * 5) * 2)
        XCTAssertEqual(preview[1].coins, (DailyBonus.base + DailyBonus.perDay * 6) * 2 + 60)
        XCTAssertEqual(preview[2].coins, DailyBonus.base + DailyBonus.perDay * 7)

        XCTAssertEqual(SavingsGoal.daysToGo(balance: 100, price: 400, perDay: 70), 5)
        XCTAssertEqual(SavingsGoal.daysToGo(balance: 500, price: 400, perDay: 0), 0)
        XCTAssertNil(SavingsGoal.daysToGo(balance: 0, price: 400, perDay: 0))
    }

    func testTheWeeksFavouriteGame() {
        var log = PlaytimeLog()
        let now = date(2026, 9, 28)
        log.add(seconds: 600, game: "Kart", at: now, calendar: calendar)
        log.add(seconds: 900, game: "Cafe", at: now, calendar: calendar)
        XCTAssertEqual(WeekSummary.make(days: log.days, ledger: CoinLedger(), now: now, calendar: calendar).favouriteGame, "Cafe")
        XCTAssertNil(WeekSummary.make(days: [], ledger: CoinLedger(), now: now, calendar: calendar).favouriteGame)
    }
}
