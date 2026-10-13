import XCTest
@testable import AbloxCore

final class FileSealTests: XCTestCase {

    func testSHA256MatchesTheStandardVectors() {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA256Digest.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256Digest.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256Digest.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // RFC 4231, test case 2.
        XCTAssertEqual(hex(SHA256Digest.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    private func backup(coins: Int) -> AbloxBackup {
        var wallet = PlayerWallet()
        wallet.earn(coins)
        _ = wallet.purchase("hat.crown")
        let record = GameSaveStore.Record(worldID: UUID(), worldName: "Shark Attack Bay", savedAt: Date(timeIntervalSince1970: 1_000),
                                          data: SaveData(["gold": .number(12.5), "harpoon": .bool(true)]))
        return AbloxBackup(profile: .default, wallet: wallet, saves: [record], worlds: [WorldDocument(name: "Mine")])
    }

    func testABackupWrittenByAbloxIsSealed() throws {
        let read = try AbloxBackup.decoded(from: try backup(coins: 300).encoded())
        XCTAssertTrue(read.isSealed)
        XCTAssertEqual(read.saves.first?.data["gold"], .number(12.5))
    }

    func testEditingTheCoinsBreaksTheSeal() throws {
        let original = backup(coins: 300)
        let text = try XCTUnwrap(String(data: try original.encoded(), encoding: .utf8))
        let coins = "\"coins\":\(original.wallet.coins)"
        XCTAssertTrue(text.contains(coins))
        let forged = Data(text.replacingOccurrences(of: coins, with: "\"coins\":999999").utf8)
        let read = try AbloxBackup.decoded(from: forged)
        XCTAssertEqual(read.wallet.coins, 999_999, "the file still opens")
        XCTAssertFalse(read.isSealed, "but its coins are not trusted")
    }

    func testABackupWithNoSealIsNotTrusted() throws {
        // What versions before seals wrote, or a sealed file with the seal deleted.
        let unsealed = try AbloxBackup.encoder.encode(backup(coins: 300))
        let read = try AbloxBackup.decoded(from: unsealed)
        XCTAssertFalse(read.isSealed)
        XCTAssertEqual(read.worlds.first?.name, "Mine")
    }

    func testTheSealIgnoresKeyOrderSoReWritingTheFileKeepsIt() throws {
        let sealed = try FileSeal.sealed(Data(#"{"b":[3,1,2],"a":{"y":true,"x":0.1}}"#.utf8))
        XCTAssertTrue(FileSeal.isIntact(sealed))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        let rewritten = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(FileSeal.isIntact(rewritten))
        XCTAssertFalse(FileSeal.isIntact(Data(#"{"a":1}"#.utf8)))
        XCTAssertFalse(FileSeal.isIntact(Data("[1,2]".utf8)))
    }

    func testOneGamesSaveFileIsSealedToo() throws {
        let record = GameSaveStore.Record(worldID: UUID(), worldName: "Pet Shop", savedAt: Date(timeIntervalSince1970: 5),
                                          data: SaveData(["coins": .number(40)]))
        let sealed = try FileSeal.sealed(GameSaveStore.encoder.encode(record))
        XCTAssertTrue(FileSeal.isIntact(sealed))
        XCTAssertEqual(try GameSaveStore.decoder.decode(GameSaveStore.Record.self, from: sealed).data["coins"], .number(40))
        let forged = Data(String(decoding: sealed, as: UTF8.self).replacingOccurrences(of: "40", with: "4000").utf8)
        XCTAssertFalse(FileSeal.isIntact(forged))
    }
}
