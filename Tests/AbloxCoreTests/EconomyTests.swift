import XCTest
@testable import AbloxCore

/// Task 6 — coins, inventory and the shop.
final class EconomyTests: XCTestCase {

    // MARK: Catalogue

    func testCatalogueIDsAreUnique() {
        let ids = ShopCatalogue.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a duplicate id would make one item unbuyable")
    }

    func testEveryItemHasThePayloadItsKindNeeds() {
        for item in ShopCatalogue.items {
            switch item.kind {
            case .bodyColor, .headColor, .accentColor:
                XCTAssertNotNil(item.color, "\(item.id) is a colour item with no colour")
            case .hat:
                XCTAssertNotNil(item.hat, "\(item.id) is a hat item with no hat")
            }
            XCTAssertGreaterThanOrEqual(item.price, 0)
            XCTAssertFalse(item.name.isEmpty)
        }
    }

    func testANewPlayerHasEnoughFreeChoicesToLookLikeThemselves() {
        let wallet = PlayerWallet()
        for kind in [ShopItem.Kind.bodyColor, .headColor, .accentColor] {
            XCTAssertGreaterThanOrEqual(
                wallet.ownedItems(of: kind).count, 4,
                "a player with no coins should still have real choices for \(kind)"
            )
        }
        XCTAssertFalse(wallet.ownedItems(of: .hat).isEmpty, "'no hat' must be owned")
    }

    func testThereIsSomethingToSaveUpFor() {
        let wallet = PlayerWallet()
        XCTAssertFalse(wallet.lockedItems(of: .hat).isEmpty)
        XCTAssertFalse(wallet.lockedItems(of: .bodyColor).isEmpty)
    }

    // MARK: Earning

    func testEarningAddsCoinsAndTracksLifetime() {
        var wallet = PlayerWallet()
        wallet.earn(30)
        wallet.earn(20)
        XCTAssertEqual(wallet.coins, 50)
        XCTAssertEqual(wallet.lifetimeEarned, 50)
    }

    func testEarningIgnoresZeroAndNegatives() {
        var wallet = PlayerWallet(coins: 10)
        wallet.earn(0)
        wallet.earn(-100)
        XCTAssertEqual(wallet.coins, 10, "a bad round must not eat coins already banked")
    }

    func testLifetimeEarnedSurvivesSpending() {
        var wallet = PlayerWallet()
        wallet.earn(100)
        let crown = ShopCatalogue.item(id: "hat.crown")!
        XCTAssertTrue(wallet.purchase(crown.id).succeeded)
        XCTAssertLessThan(wallet.coins, 100)
        XCTAssertEqual(wallet.lifetimeEarned, 100, "career total should not go down when you spend")
    }

    func testCoinRateFloorsNegativeScores() {
        XCTAssertEqual(CoinRate.coins(forScore: 40), 40)
        XCTAssertEqual(CoinRate.coins(forScore: -10), 0, "a negative round earns nothing, it does not charge you")
        XCTAssertEqual(
            CoinRate.coins(forScore: 40, completedRound: true),
            40 + CoinRate.roundCompletionBonus
        )
    }

    // MARK: Purchasing

    func testBuyingDeductsAndUnlocks() {
        var wallet = PlayerWallet()
        wallet.earn(200)
        let crown = ShopCatalogue.item(id: "hat.crown")!

        XCTAssertFalse(wallet.owns(crown))
        let result = wallet.purchase(crown.id)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(wallet.owns(crown))
        XCTAssertEqual(wallet.coins, 200 - crown.price)
    }

    func testCannotBuyWhatYouCannotAfford() {
        var wallet = PlayerWallet()
        wallet.earn(5)
        let crown = ShopCatalogue.item(id: "hat.crown")!

        let result = wallet.purchase(crown.id)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result, .notEnoughCoins(shortfall: crown.price - 5))
        XCTAssertEqual(wallet.coins, 5, "a failed purchase must not charge")
        XCTAssertFalse(wallet.owns(crown))
    }

    func testShortfallMessageIsGrammatical() {
        XCTAssertTrue(PlayerWallet.PurchaseResult.notEnoughCoins(shortfall: 1).message.contains("1 more coin"))
        XCTAssertTrue(PlayerWallet.PurchaseResult.notEnoughCoins(shortfall: 5).message.contains("5 more coins"))
    }

    func testBuyingTwiceDoesNotChargeTwice() {
        var wallet = PlayerWallet()
        wallet.earn(500)
        let crown = ShopCatalogue.item(id: "hat.crown")!

        XCTAssertTrue(wallet.purchase(crown.id).succeeded)
        let after = wallet.coins
        XCTAssertEqual(wallet.purchase(crown.id), .alreadyOwned)
        XCTAssertEqual(wallet.coins, after, "re-buying must be free and harmless")
    }

    func testUnknownItemIsRejected() {
        var wallet = PlayerWallet()
        wallet.earn(999)
        XCTAssertEqual(wallet.purchase("hat.sombrero"), .unknownItem)
        XCTAssertEqual(wallet.coins, 999)
    }

    func testFreeItemsAreOwnedWithoutBuying() {
        let wallet = PlayerWallet()
        let free = ShopCatalogue.items.first { $0.isFree }!
        XCTAssertTrue(wallet.owns(free))
    }

    func testCoinsCanNeverGoNegative() {
        var wallet = PlayerWallet()
        wallet.earn(10)
        for item in ShopCatalogue.items {
            _ = wallet.purchase(item.id)
        }
        XCTAssertGreaterThanOrEqual(wallet.coins, 0)
    }

    // MARK: Persistence

    func testWalletRoundTrips() throws {
        var wallet = PlayerWallet()
        wallet.earn(300)
        _ = wallet.purchase("hat.crown")

        let restored = try JSONDecoder().decode(PlayerWallet.self, from: JSONEncoder().encode(wallet))
        XCTAssertEqual(restored.coins, wallet.coins)
        XCTAssertEqual(restored.ownedItemIDs, wallet.ownedItemIDs)
        XCTAssertEqual(restored.lifetimeEarned, wallet.lifetimeEarned)
    }

    func testFreeItemsAddedInALaterVersionAreGrantedOnLoad() throws {
        // A wallet saved before a free item existed must not show it locked.
        let json = #"{"coins":10,"ownedItemIDs":[],"lifetimeEarned":10}"#
        let restored = try JSONDecoder().decode(PlayerWallet.self, from: Data(json.utf8))
        XCTAssertTrue(restored.ownedItemIDs.isSuperset(of: ShopCatalogue.freeItemIDs))
        XCTAssertEqual(restored.coins, 10)
    }

    func testResetClearsPurchasesButKeepsFreeItems() {
        var wallet = PlayerWallet()
        wallet.earn(500)
        _ = wallet.purchase("hat.crown")

        wallet.reset()
        XCTAssertEqual(wallet.coins, 0)
        XCTAssertEqual(wallet.lifetimeEarned, 0)
        XCTAssertFalse(wallet.owns("hat.crown"))
        XCTAssertTrue(wallet.ownedItemIDs.isSuperset(of: ShopCatalogue.freeItemIDs))
    }

    // MARK: Fairness

    func testNothingInTheShopAffectsGameplay() {
        // The design rule, asserted rather than just documented: shop items
        // only carry appearance payloads. If a speed or reach field is ever
        // added to ShopItem, this test is where it gets argued about.
        for item in ShopCatalogue.items {
            XCTAssertTrue(
                item.color != nil || item.hat != nil,
                "\(item.id) carries something that is not appearance"
            )
        }
    }
}
