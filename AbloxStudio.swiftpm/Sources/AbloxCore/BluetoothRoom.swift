import Foundation

/// A room nearby over Bluetooth, as its host describes it: what a guest
/// reads from the room's Bluetooth service before it joins (Net/
/// BluetoothRelay.swift carries the connection itself).
///
/// The same room as on the router and the internet: one listener, one code,
/// one key salt. Bluetooth is only another way in, as the database is for
/// internet rooms — the bytes are the room's TLS stream, so nothing here is
/// a secret but the code of a private room, which is left out.
public struct BluetoothRoomInfo: Codable, Hashable, Sendable {
    /// Bluetooth's service and the room's description in it.
    public static let serviceID = "A3B10C00-0000-4000-8000-00000000B1E0"
    public static let infoID = "A3B10C00-0000-4000-8000-00000000B1E1"
    /// The description is read in pieces; past this it is not believed.
    public static let maximumBytes = 1024

    /// The L2CAP channel to open (its "PSM").
    public var channel: UInt16
    public var world: String
    public var hostName: String
    /// `RoomTag.short` of the host, to follow a room that moves.
    public var hostShortID: String
    public var players: Int
    public var capacity: Int
    public var protocolVersion: Int
    /// The code, for a public room only: a private room's code is on the
    /// host's screen, never in the air.
    public var publicCode: String?
    /// Mixed into the key made from the code (`TLSPeerSecurity`).
    public var salt: String
    public var needsApproval: Bool

    private enum CodingKeys: String, CodingKey {
        case channel = "psm", world, hostName = "host", hostShortID = "id", players, capacity,
             protocolVersion = "protocol", publicCode = "code", salt, needsApproval = "ask"
    }

    public init(channel: UInt16, world: String, hostName: String, hostShortID: String, players: Int, capacity: Int,
                protocolVersion: Int = AbloxProtocol.version, publicCode: String?, salt: String, needsApproval: Bool = false) {
        self.channel = channel
        self.world = String(world.prefix(60))
        self.hostName = String(hostName.prefix(40))
        self.hostShortID = String(hostShortID.prefix(16))
        self.players = max(0, min(players, 999))
        self.capacity = max(1, min(capacity, 999))
        self.protocolVersion = protocolVersion
        self.publicCode = publicCode.map(RoomCodeFormat.normalize).flatMap { RoomCodeFormat.isPlausible($0) ? $0 : nil }
        self.salt = salt.lowercased()
        self.needsApproval = needsApproval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(channel: try c.decode(UInt16.self, forKey: .channel),
                  world: try c.decode(String.self, forKey: .world),
                  hostName: try c.decode(String.self, forKey: .hostName),
                  hostShortID: try c.decode(String.self, forKey: .hostShortID),
                  players: try c.decode(Int.self, forKey: .players),
                  capacity: try c.decode(Int.self, forKey: .capacity),
                  protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                  publicCode: try c.decodeIfPresent(String.self, forKey: .publicCode),
                  salt: try c.decode(String.self, forKey: .salt),
                  needsApproval: try c.decodeIfPresent(Bool.self, forKey: .needsApproval) ?? false)
    }

    /// The description as it goes into the air.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// A description read from a room nearby, if it is whole and makes sense.
    public static func decode(_ data: Data) -> BluetoothRoomInfo? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let info = try? JSONDecoder().decode(BluetoothRoomInfo.self, from: data),
              info.channel > 0, JoinTicket.isPlausibleSalt(info.salt), !info.world.isEmpty else { return nil }
        return info
    }

    public var isPublic: Bool { publicCode != nil }
    public var isFull: Bool { players >= capacity }
    public var isCompatible: Bool { protocolVersion == AbloxProtocol.version }

    /// What joining needs, pointed at this iPad's end of the Bluetooth link,
    /// with the code typed in (or the room's own, when it is public).
    public func ticket(localPort: UInt16, code: String? = nil) -> JoinTicket? {
        guard let code = code ?? publicCode else { return nil }
        return JoinTicket(host: "127.0.0.1", port: localPort, salt: salt, code: code, world: world)
    }

    /// The part of a reply to a read at `offset`: Bluetooth reads a long
    /// value in pieces, each asking from where the last one stopped. Nil for
    /// an offset past the end.
    public static func piece(of value: Data, at offset: Int) -> Data? {
        guard offset >= 0, offset <= value.count else { return nil }
        return value.subdata(in: value.startIndex + offset ..< value.endIndex)
    }
}
