import XCTest
@testable import AbloxCore

/// A room nearby over Bluetooth: what its host puts in the air, and what a
/// guest believes of what it reads.
final class BluetoothRoomTests: XCTestCase {

    private let salt = "0123456789abcdef0123456789abcdef"

    func testADescriptionReadsBackAsItWasWritten() {
        let info = BluetoothRoomInfo(channel: 193, world: "Meme Heist", hostName: "Sam", hostShortID: "AB12CD",
                                     players: 3, capacity: 8, publicCode: "abc-def", salt: salt.uppercased(), needsApproval: true)
        let back = BluetoothRoomInfo.decode(info.encoded())
        XCTAssertEqual(back, info)
        XCTAssertEqual(back?.publicCode, "ABCDEF")
        XCTAssertEqual(back?.salt, salt)
        XCTAssertTrue(back?.isCompatible ?? false)
        XCTAssertLessThan(info.encoded().count, BluetoothRoomInfo.maximumBytes)
    }

    func testAPrivateRoomKeepsItsCodeOutOfTheAir() {
        let info = BluetoothRoomInfo(channel: 193, world: "Obby", hostName: "Sam", hostShortID: "AB12CD",
                                     players: 1, capacity: 4, publicCode: nil, salt: salt)
        XCTAssertFalse(String(decoding: info.encoded(), as: UTF8.self).contains("\"code\""))
        XCTAssertNil(info.ticket(localPort: 5000), "joining a private room needs the code typed in")
        let ticket = info.ticket(localPort: 5000, code: "QRST23")
        XCTAssertEqual(ticket?.host, "127.0.0.1")
        XCTAssertEqual(ticket?.port, 5000)
        XCTAssertEqual(ticket?.code, "QRST23")
    }

    func testWhatMakesNoSenseIsNotBelieved() {
        XCTAssertNil(BluetoothRoomInfo.decode(Data()))
        XCTAssertNil(BluetoothRoomInfo.decode(Data("not json".utf8)))
        XCTAssertNil(BluetoothRoomInfo.decode(Data(repeating: 0x20, count: BluetoothRoomInfo.maximumBytes + 1)))
        let noChannel = BluetoothRoomInfo(channel: 0, world: "W", hostName: "H", hostShortID: "X", players: 1, capacity: 2,
                                          publicCode: nil, salt: salt)
        XCTAssertNil(BluetoothRoomInfo.decode(noChannel.encoded()))
        let badSalt = BluetoothRoomInfo(channel: 9, world: "W", hostName: "H", hostShortID: "X", players: 1, capacity: 2,
                                        publicCode: nil, salt: "not-hex")
        XCTAssertNil(BluetoothRoomInfo.decode(badSalt.encoded()))
        let long = BluetoothRoomInfo(channel: 9, world: String(repeating: "W", count: 500), hostName: "H", hostShortID: "X",
                                     players: 5000, capacity: 0, publicCode: "no", salt: salt)
        XCTAssertEqual(long.world.count, 60)
        XCTAssertEqual(long.players, 999)
        XCTAssertEqual(long.capacity, 1)
        XCTAssertNil(long.publicCode, "a code too short to be one is not one")
    }

    func testALongDescriptionIsReadInPieces() {
        let value = Data((0..<300).map { UInt8($0 % 256) })
        XCTAssertEqual(BluetoothRoomInfo.piece(of: value, at: 0), value)
        XCTAssertEqual(BluetoothRoomInfo.piece(of: value, at: 182)?.count, 118)
        XCTAssertEqual(BluetoothRoomInfo.piece(of: value, at: 300), Data())
        XCTAssertNil(BluetoothRoomInfo.piece(of: value, at: 301))
        XCTAssertNil(BluetoothRoomInfo.piece(of: value, at: -1))
    }
}
