import XCTest
@testable import AbloxCore

final class DownloadProgressTests: XCTestCase {

    func testMegabytesReadTheWayTheGamesTabSaysThem() {
        XCTAssertEqual(Megabytes.number(0), "0.0")
        XCTAssertEqual(Megabytes.number(1), "0.1", "anything at all is at least 0.1 MB")
        XCTAssertEqual(Megabytes.number(1_048_576), "1.0")
        XCTAssertEqual(Megabytes.number(12_900_000), "12.3")
        XCTAssertTrue(Megabytes.text(3 * 1_073_741_824).hasPrefix("3.0"), "gigabytes past 1024 MB")
    }

    func testAMeterWithAndWithoutASize() {
        let known = DownloadMeter(received: 524_288, expected: 1_048_576)
        XCTAssertEqual(known.fraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertTrue(known.text.contains("0.5"))
        XCTAssertTrue(known.text.contains("1.0"))
        let unknown = DownloadMeter(received: 524_288)
        XCTAssertNil(unknown.fraction)
        XCTAssertEqual(unknown.text, Megabytes.text(524_288))
        // A server that under-declared: more arrived than it said.
        let over = DownloadMeter(received: 2_000_000, expected: 1_000_000)
        XCTAssertEqual(over.fraction, 1)
        XCTAssertEqual(over.text, Megabytes.text(2_000_000))
        XCTAssertNil(DownloadMeter(received: 5, expected: 0).expected, "a size of nothing is no size")
    }

    func testEveryGameAddsUp() {
        var bulk = BulkDownload(total: 4)
        XCTAssertEqual(bulk.fraction, 0)
        bulk.done = 2
        bulk.current = "Next"
        bulk.currentMeter = DownloadMeter(received: 50, expected: 100)
        XCTAssertEqual(bulk.fraction, 0.625, accuracy: 0.0001, "two done and half of the third")
        bulk.bytes = 3_145_728
        XCTAssertTrue(bulk.summary.contains("2"))
        XCTAssertTrue(bulk.summary.contains("3.0"))

        var sized = BulkDownload(total: 2, expectedBytes: 4_194_304)
        sized.bytes = 1_048_576
        XCTAssertEqual(sized.fraction, 0.25, accuracy: 0.0001, "by bytes when every size is known")
        XCTAssertTrue(sized.summary.contains("1.0"))
        XCTAssertTrue(sized.summary.contains("4.0"))
        XCTAssertEqual(BulkDownload(total: 0).fraction, 1)
    }

    func testTheListingsSizeIsOptionalAndBelievable() throws {
        let old = #"{"id":"sky","title":"Sky","author":"","summary":"","world":"games/sky/world.ablox","tags":[],"blockCount":1,"maxPlayers":4,"schemaVersion":1,"updatedAt":"2026-09-24T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let listing = try decoder.decode(GameListing.self, from: Data(old.utf8))
        XCTAssertNil(listing.bytes, "lists from before the size still read")
        XCTAssertNil(listing.downloadSize)

        var sized = listing
        sized.bytes = 1_234_567
        let data = try JSONEncoder().encode(sized)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"bytes\":1234567"))
        XCTAssertEqual(sized.downloadSize, 1_234_567)
        sized.bytes = -3
        XCTAssertNil(sized.downloadSize)
        sized.bytes = Int.max
        XCTAssertNil(sized.downloadSize, "bigger than a world may be")
    }
}
