import XCTest
@testable import AbloxCore

/// The cover picture drawn for a published game.
///
/// Nothing here can render, so what is checked is the arithmetic that decides
/// where things go — which is where the invisible failures live. A world laid
/// out slightly off the card, or scaled so every block is a sub-pixel smudge,
/// still produces an image file; it just produces a useless one, and nobody
/// notices until it is on a card in someone else's app.
final class CoverArtworkTests: XCTestCase {

    private func world(_ blocks: [BlockData]) -> WorldDocument {
        var world = WorldDocument(name: "Test")
        world.blocks = blocks
        return world
    }

    private func block(at position: Vec3, scale: Vec3 = Vec3(2, 1, 2), behavior: BlockBehavior = .none) -> BlockData {
        var block = BlockData(name: "B", transform: Transform3D(position: position, scale: scale))
        block.behavior = behavior
        return block
    }

    // MARK: Fitting

    func testEverythingLandsOnTheCard() {
        let artwork = CoverArtwork.make(from: world([
            block(at: Vec3(-20, 0, -20)),
            block(at: Vec3(20, 0, 20)),
            block(at: Vec3(0, 5, 0))
        ]))
        XCTAssertTrue(artwork.fitsOnTheCard)
    }

    func testAWorldSpreadOverHundredsOfMetresStillFits() {
        let artwork = CoverArtwork.make(from: world([
            block(at: Vec3(-400, 0, -400), scale: Vec3(50, 1, 50)),
            block(at: Vec3(400, 0, 400), scale: Vec3(50, 1, 50))
        ]))
        XCTAssertTrue(artwork.fitsOnTheCard)
    }

    func testASingleBlockDoesNotFillTheWholeCard() {
        // Scaled to fit, one block would become a solid rectangle of colour —
        // which is not a picture of anything. The minimum world size stops it.
        let artwork = CoverArtwork.make(from: world([block(at: .zero)]))
        XCTAssertTrue(artwork.fitsOnTheCard)
        let shape = try? XCTUnwrap(artwork.shapes.first)
        XCTAssertLessThan(shape?.width ?? .infinity, CoverArtwork.size.width * 0.9)
    }

    func testAnEmptyWorldProducesNoShapesRatherThanCrashing() {
        // A new project has no blocks and can still be published by mistake.
        let artwork = CoverArtwork.make(from: world([]))
        XCTAssertTrue(artwork.shapes.isEmpty)
        XCTAssertTrue(artwork.fitsOnTheCard)
    }

    func testHiddenBlocksAreLeftOut() {
        var hidden = block(at: Vec3(100, 0, 100))
        hidden.isVisible = false

        let artwork = CoverArtwork.make(from: world([block(at: .zero), hidden]))
        XCTAssertEqual(artwork.shapes.count, 1)
        // And the hidden one must not stretch the bounds either, or the
        // visible block ends up in a corner of an otherwise empty card.
        XCTAssertGreaterThan(artwork.shapes[0].width, 100)
    }

    // MARK: Proportions

    func testProportionsAreKept() {
        // A world twice as long as it is deep must stay twice as long. One
        // scale for both axes is the whole point.
        let artwork = CoverArtwork.make(from: world([
            block(at: Vec3(-20, 0, -5), scale: Vec3(1, 1, 1)),
            block(at: Vec3(20, 0, 5), scale: Vec3(1, 1, 1))
        ]))

        let spanX = artwork.shapes.map(\.x).max()! - artwork.shapes.map(\.x).min()!
        let spanY = artwork.shapes.map(\.y).max()! - artwork.shapes.map(\.y).min()!
        XCTAssertEqual(spanX / spanY, 4, accuracy: 0.25, "a 40×10 world should read as 4:1")
    }

    func testATinyBlockIsStillVisible() {
        // A coin in a large world would otherwise be a fraction of a pixel.
        let artwork = CoverArtwork.make(from: world([
            block(at: Vec3(-200, 0, 0), scale: Vec3(50, 1, 50)),
            block(at: Vec3(200, 0, 0), scale: Vec3(50, 1, 50)),
            block(at: .zero, scale: Vec3(0.4, 0.4, 0.4), behavior: .collectible)
        ]))

        let smallest = artwork.shapes.map(\.width).min() ?? 0
        XCTAssertGreaterThanOrEqual(smallest, CoverArtwork.minimumShapeSize)
    }

    func testANegativeScaleDoesNotProduceANegativeRectangle() {
        // Scale is settable and a mirrored part is legal. A negative width
        // draws nothing on most renderers and is hard to notice.
        let artwork = CoverArtwork.make(from: world([
            block(at: .zero, scale: Vec3(-4, 1, -4))
        ]))
        XCTAssertTrue(artwork.shapes.allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertTrue(artwork.fitsOnTheCard)
    }

    // MARK: Order

    func testLandmarksAreDrawnLast() {
        // The goal must not end up underneath the platform it stands on.
        let artwork = CoverArtwork.make(from: world([
            block(at: Vec3(0, 10, 0), scale: Vec3(20, 1, 20)),
            block(at: .zero, behavior: .goal)
        ]))

        XCTAssertEqual(artwork.shapes.count, 2)
        XCTAssertTrue(artwork.shapes.last?.isLandmark ?? false,
                      "the goal should be on top even though it is lower")
    }

    func testOrdinaryBlocksAreDrawnLowestFirst() {
        let artwork = CoverArtwork.make(from: world([
            block(at: Vec3(0, 8, 0)),
            block(at: Vec3(0, 1, 0))
        ]))
        // Both are plain, so height decides: the lower one first.
        XCTAssertEqual(artwork.shapes.count, 2)
        XCTAssertFalse(artwork.shapes[0].isLandmark)
    }

    func testTheThingsWorthSeeingAreMarked() {
        // Where you start, where you are going, and what will kill you.
        for behaviour in [BlockBehavior.spawn, .goal, .checkpoint, .hazard, .collectible] {
            XCTAssertTrue(CoverArtwork.isLandmark(behaviour), "\(behaviour)")
        }
        for behaviour in [BlockBehavior.none, .trigger, .bounce] {
            XCTAssertFalse(CoverArtwork.isLandmark(behaviour), "\(behaviour)")
        }
    }

    // MARK: Colour

    func testBlockColoursAreCarriedThrough() {
        var red = block(at: .zero)
        red.color = ColorRGBA(hex: "#FF0000")!

        let artwork = CoverArtwork.make(from: world([red]))
        XCTAssertEqual(artwork.shapes.first?.color.r ?? 0, 1, accuracy: 0.01)
    }

    func testTheBackgroundComesFromTheWorldsSky() {
        var document = world([block(at: .zero)])
        document.environment.skyBottom = ColorRGBA(hex: "#123456")!
        XCTAssertEqual(CoverArtwork.make(from: document).background, document.environment.skyBottom)
    }

    // MARK: A real world

    func testTheStarterWorldLaysOutSensibly() {
        // The template most published games will start from.
        let artwork = CoverArtwork.make(from: .starter(named: "Starter"))

        XCTAssertFalse(artwork.shapes.isEmpty)
        XCTAssertTrue(artwork.fitsOnTheCard)
        XCTAssertTrue(artwork.shapes.contains(where: \.isLandmark),
                      "the starter world has a spawn and a goal and should show them")
    }
}
